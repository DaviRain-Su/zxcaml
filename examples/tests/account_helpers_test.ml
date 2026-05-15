let sample_account =
  {
    key = Bytes.of_string "authority";
    lamports = 42;
    data = Bytes.of_string "abc";
    owner = Bytes.of_string "owner";
    is_signer = true;
    is_writable = false;
    executable = false;
  }

let%test_unit "account field helpers" =
  assert (Bytes.equal (Account.key sample_account) (Bytes.of_string "authority"));
  assert (Bytes.equal (Account.owner sample_account) (Bytes.of_string "owner"));
  assert (Bytes.equal (Account.data sample_account) (Bytes.of_string "abc"));
  assert (Account.lamports sample_account = 42);
  assert (Account.data_len sample_account = 3)

let%test_unit "account predicate helpers" =
  assert (Account.is_signer sample_account);
  assert (not (Account.is_writable sample_account));
  assert (not (Account.is_executable sample_account));
  assert (Account.has_key sample_account (Bytes.of_string "authority"));
  assert (Account.is_owned_by sample_account (Bytes.of_string "owner"))
