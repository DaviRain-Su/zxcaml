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

let value = Account.has_key sample_account 1
