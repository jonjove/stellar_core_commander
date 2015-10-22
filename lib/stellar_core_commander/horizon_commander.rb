require 'typhoeus'
require 'typhoeus/adapters/faraday'

module StellarCoreCommander

  class HorizonCommander
    include Contracts
    include Concerns::NamedObjects
    include Concerns::TracksAccounts

    Contract String => Any
    def initialize(endpoint)
      @endpoint = endpoint
      @open = {}
      @sequences = SequenceTracker.new(self)
      @conn = Faraday.new(:url => @endpoint) do |faraday|
        faraday.adapter :typhoeus
      end

      @operation_builder = OperationBuilder.new(self)
      account :master, Stellar::KeyPair.master
    end


    Contract String => Any
    #
    # Runs the provided recipe against the process identified by @process
    #
    # @param recipe_path [String] path to the recipe file
    #
    def run_recipe(recipe_path)
      recipe_content = IO.read(recipe_path)

      @conn.in_parallel do
        instance_eval recipe_content, recipe_path, 1
        wait
      end

    rescue => e
      crash_recipe e
    end

    def wait
      $stderr.puts "waiting for all open txns"
      @conn.parallel_manager.run
      
      @open.each do |sequence, info|
        unless info[:resp].success?
          require 'pry'; binding.pry
          raise "transaction failed"
        end
      end

      @open = {}
    end



    Contract ArrayOf[Symbol] => Any
    def self.recipe_steps(names)
      names.each do |name|
        define_method name do |*args|
          envelope = @operation_builder.send(name, *args)
          submit_transaction envelope
        end
      end
    end

    recipe_steps [
      :payment,
      :create_account,
      :trust,
      :change_trust,
      :offer,
      :passive_offer,
      :set_options,
      :set_flags,
      :clear_flags,
      :require_trust_auth,
      :add_signer,
      :set_master_signer_weight,
      :remove_signer,
      :set_thresholds,
      :set_inflation_dest,
      :set_home_domain,
      :allow_trust,
      :revoke_trust,
      :merge_account,
      :inflation,
    ]

    delegate :next_sequence, to: :@sequences


    Contract Stellar::KeyPair => Num
    def sequence_for(account)
      resp = Typhoeus.get("#{@endpoint}/accounts/#{account.address}")
      raise "couldn't get sequence for #{account.address}" unless resp.success?
      body = ActiveSupport::JSON.decode resp.body
      body["sequence"]
    end


    private


    Contract Stellar::TransactionEnvelope, Or[nil, Proc] => Any
    def submit_transaction(envelope, &after_confirmation)
      sequence = envelope.tx.seq_num
      b64 = envelope.to_xdr(:base64)
      resp = @conn.post("transactions", tx: b64)

      resp.on_complete do |env|
        next if env.success?
        retries = @open[sequence][:retries] - 1
        next if retries <= 0

        $stderr.puts "retry: #{retries} left"
        # requeue request
        @open[sequence] = {resp: @conn.post("transactions", tx: b64), retries: retries}
      end

      @open[sequence] = {resp: resp, retries: 3}
    end

    Contract Exception => Any
    def crash_recipe(e)
      puts
      puts "Error! (#{e.class.name}): #{e.message}"
      puts
      puts e.backtrace.
        reject{|l| l =~ %r{gems/contracts-.+?/} }. # filter contract frames
        join("\n")
      puts

      exit 1
    end

  end
end
