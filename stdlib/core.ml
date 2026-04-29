(* Core standard-library subset for ZxCaml.

   This module contains the small OCaml definitions that the P1 frontend and
   downstream pipeline agree to support.  It is intentionally valid upstream
   OCaml so ocamlc can type-check it as an oracle while ZxCaml grows its own
   runtime representation. *)

type 'a option = None | Some of 'a

type ('a, 'b) result = Ok of 'a | Error of 'b

type account = {
  key : bytes;
  lamports : int;
  data : bytes;
  owner : bytes;
  is_signer : bool;
  is_writable : bool;
  executable : bool;
}

type account_meta = {
  pubkey : bytes;
  is_writable : bool;
  is_signer : bool;
}

type instruction = {
  program_id : bytes;
  accounts : account_meta array;
  data : bytes;
}

type pubkey = bytes

type signer_seeds = bytes array

type error = {
  program_id_index : int;
  code : int;
}

type clock = {
  slot : int;
  epoch_start_timestamp : int;
  epoch : int;
  leader_schedule_epoch : int;
  unix_timestamp : int;
}

module Option = struct
  let map f = function None -> None | Some x -> Some (f x)

  let bind x f = match x with None -> None | Some v -> f v

  let is_none x = match x with None -> true | Some _ -> false

  let is_some x = match x with None -> false | Some _ -> true

  let value x default = match x with None -> default | Some v -> v

  let rec unreachable () = unreachable ()

  let get x = match x with Some v -> v | None -> unreachable ()
end

module Result = struct
  let map f = function Ok x -> Ok (f x) | Error e -> Error e

  let bind x f = match x with Ok v -> f v | Error e -> Error e

  let is_ok x = match x with Ok _ -> true | Error _ -> false

  let is_error x = match x with Ok _ -> false | Error _ -> true

  let ok x = match x with Ok v -> Some v | Error _ -> None

  let error x = match x with Ok _ -> None | Error e -> Some e
end

module List = struct
  let rec length xs = match xs with [] -> 0 | _ :: rest -> 1 + length rest

  let rec map f xs =
    match xs with [] -> [] | x :: rest -> f x :: map f rest

  let rec filter predicate xs =
    match xs with
    | [] -> []
    | x :: rest ->
        if predicate x then x :: filter predicate rest else filter predicate rest

  let rec fold_left f acc xs =
    match xs with [] -> acc | x :: rest -> fold_left f (f acc x) rest

  let rev xs = fold_left (fun acc x -> x :: acc) [] xs

  let rec append left right =
    match left with [] -> right | x :: rest -> x :: append rest right

  let rec unreachable () = unreachable ()

  let hd xs = match xs with [] -> unreachable () | x :: _ -> x

  let tl xs = match xs with [] -> unreachable () | _ :: rest -> rest
end

module Syscall = struct
  external sol_log : string -> unit = "sol_log_"

  external sol_log_64 : int -> int -> int -> int -> int -> unit = "sol_log_64_"

  external sol_sha256 : 'a -> 'a = "sol_sha256"

  external sol_get_clock_sysvar : unit -> clock = "sol_get_clock_sysvar"

  external sol_remaining_compute_units : unit -> int
    = "sol_remaining_compute_units"
end

module Pubkey = struct
  let zero : pubkey = Bytes.make 32 '\000'

  let token_program : pubkey =
    Bytes.of_string
      "\006\221\246\225\215\101\161\147\217\203\225\070\206\235\121\172\028\180\133\237\095\091\055\145\058\140\245\133\126\255\000\169"

  let of_hex hex : pubkey =
    let hex_nibble c =
      match c with
      | '0' .. '9' -> Char.code c - Char.code '0'
      | 'a' .. 'f' -> 10 + Char.code c - Char.code 'a'
      | 'A' .. 'F' -> 10 + Char.code c - Char.code 'A'
      | _ -> invalid_arg "Pubkey.of_hex: non-hex character"
    in
    if String.length hex <> 64 then
      invalid_arg "Pubkey.of_hex: expected exactly 64 hex characters";
    let out = Bytes.create 32 in
    for index = 0 to 31 do
      let high = hex_nibble (String.get hex (index * 2)) in
      let low = hex_nibble (String.get hex ((index * 2) + 1)) in
      Bytes.set out index (Char.chr ((high * 16) + low))
    done;
    out
end

module Error = struct
  let make program_id_index code = { program_id_index; code }

  let encode err = (err.program_id_index * 256) + err.code

  let encode_code program_id_index code = (program_id_index * 256) + code
end

let invoke (_instruction : instruction) = 0

let invoke_signed (_instruction : instruction) (_signer_seeds : signer_seeds array)
    =
  0

let create_program_address (_seeds : signer_seeds) (program_id : bytes) =
  program_id

let try_find_program_address (_seeds : signer_seeds) (program_id : bytes) =
  Some (program_id, 0)

let head xs = match xs with [] -> None | x :: _ -> Some x

let tail xs = match xs with [] -> None | _ :: rest -> Some rest
