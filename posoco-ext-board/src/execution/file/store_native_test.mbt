///|
async test "native file facade retains exclusive ownership against a rejected client" {
  let directory = @fixtures.temporary_directory()
  defer @fixtures.cleanup(directory)
  let owner = @file.FileBoardExecutionStore(directory~)
  defer owner.close()
  assert_eq(owner.load(), Ok([]))
  let competitor = @file.FileBoardExecutionStore(directory~)
  assert_eq(competitor.load(), Err(@execution.StoreUnavailable))
  competitor.close()
  let third = @file.FileBoardExecutionStore(directory~)
  assert_eq(third.load(), Err(@execution.StoreUnavailable))
  third.close()
  owner.close()
  let restarted = @file.FileBoardExecutionStore(directory~)
  defer restarted.close()
  assert_eq(restarted.load(), Ok([]))
}
