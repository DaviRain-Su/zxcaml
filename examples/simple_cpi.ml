(* Demonstrates P3 cross-program invocation (CPI).
   The instruction below is shaped like a System Program transfer: it names the
   callee program, marks source/destination account metas, supplies transfer
   data, and invokes without PDA signer seeds because the outer instruction
   already provides the source signer. *)

external log_message : string -> unit = "sol_log_"

let entrypoint accounts _input =
  let _ = accounts in
  let _ = log_message "simple CPI via external binding" in
  (* CPI construction: invoke forwards signer/writable privileges from the
     current instruction; no PDA signer seeds are needed for a plain transfer. *)
  invoke
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
