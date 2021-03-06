process :node1, [:node1, :node2, :node3], await_sync: false
process :node2, [:node1, :node2, :node3], await_sync: false
process :node3, [:node1, :node2, :node3]

on :node1 do
  generate_load_and_await_completion 10000, 10000, :auto
end

on :node2 do
  check_integrity_against :node1
end

on :node3 do
  check_integrity_against :node1
end
