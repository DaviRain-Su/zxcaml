let entrypoint _input =
  let amount = 1 in
  let _ = amount in
  invoke_signed
    {
      program_id =
        Bytes.of_string
          "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA";
      accounts =
        Array.of_list
          [
            { pubkey = Bytes.of_string ""; is_writable = true; is_signer = false };
            { pubkey = Bytes.of_string ""; is_writable = true; is_signer = false };
            { pubkey = Bytes.of_string ""; is_writable = false; is_signer = true };
          ];
      data = Bytes.of_string "\003\001\000\000\000\000\000\000\000";
    }
    (Array.of_list [])
