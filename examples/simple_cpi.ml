(* Demonstrates P3 cross-program invocation (CPI).
   The instruction below is shaped like a System Program transfer: it names the
   callee program, marks source/destination account metas, supplies transfer
   data, and invokes with signer seeds. *)

let entrypoint accounts input =
  let _ = accounts in
  let _ = input in
  (* CPI construction: invoke_signed receives the instruction record and the
     signer seed arrays needed when a program signs on behalf of a PDA. *)
  invoke_signed
    {
      (* The native System Program has the all-zero 32-byte program id. *)
      program_id = Pubkey.zero;
      (* Account metas describe the privileges forwarded to the callee:
         a writable signer source and a writable non-signer destination. *)
      accounts =
        Array.of_list
          [
            {
              pubkey = Pubkey.zero;
              is_writable = true;
              is_signer = true;
            };
            {
              pubkey = Pubkey.zero;
              is_writable = true;
              is_signer = false;
            };
          ];
      (* System transfer instruction data: discriminator 2 plus amount 1
         encoded as little-endian bytes for the runtime CPI helper. *)
      data =
        Bytes.of_string
          "\002\000\000\000\001\000\000\000\000\000\000\000";
    }
    (* Signer seeds are nested arrays of byte slices; this smoke test includes
       one seed group containing the literal "zxcaml". *)
    (Array.of_list [ Array.of_list [ Bytes.of_string "zxcaml" ] ])
