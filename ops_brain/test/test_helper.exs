ExUnit.start()
{:ok, _} = OpsBrain.TestAdminRepo.start_link()
OpsBrain.DatabaseSafety.verify!()
