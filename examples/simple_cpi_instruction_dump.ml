(* Focused CPI fixture that forces the generic invoke_signed staging path so a
   callee can dump the observed program id, account metas, and data bytes. *)

let dump_program_id = Bytes.of_string "PPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPP"

let readonly_account = Bytes.of_string "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

let writable_account = Bytes.of_string "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"

let signer_account = Bytes.of_string "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"

let writable_signer_account = Bytes.of_string "DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD"

let entrypoint _accounts _input =
  Cpi.invoke_signed
    {
      program_id = dump_program_id;
      accounts =
        Array.of_list
          [
            {
              pubkey = readonly_account;
              is_writable = false;
              is_signer = false;
            };
            {
              pubkey = writable_account;
              is_writable = true;
              is_signer = false;
            };
            { pubkey = signer_account; is_writable = false; is_signer = true };
            {
              pubkey = writable_signer_account;
              is_writable = true;
              is_signer = true;
            };
          ];
      data = Bytes.of_string "A\000Z?*b!";
    }
    (Array.of_list [])
