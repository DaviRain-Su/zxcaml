let entrypoint _input =
  invoke_signed
    {
      program_id =
        Bytes.of_string
          "\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000";
      accounts =
        Array.of_list
          [
            {
              pubkey =
                Bytes.of_string
                  "\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000";
              is_writable = true;
              is_signer = true;
            };
            {
              pubkey =
                Bytes.of_string
                  "\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000";
              is_writable = true;
              is_signer = false;
            };
          ];
      data =
        Bytes.of_string
          "\002\000\000\000\001\000\000\000\000\000\000\000";
    }
    (Array.of_list [ Array.of_list [ Bytes.of_string "zxcaml" ] ])
