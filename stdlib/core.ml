(* Core standard-library subset for ZxCaml.

   This module contains the small OCaml definitions that the P1 frontend and
   downstream pipeline agree to support.  It is intentionally valid upstream
   OCaml so ocamlc can type-check it as an oracle while ZxCaml grows its own
   runtime representation. *)

type 'a option = None | Some of 'a

type ('a, 'b) result = Ok of 'a | Error of 'b

module Option = struct
  let map f = function None -> None | Some x -> Some (f x)

  let bind x f = match x with None -> None | Some v -> f v
end

module Result = struct
  let map f = function Ok x -> Ok (f x) | Error e -> Error e

  let bind x f = match x with Ok v -> f v | Error e -> Error e
end

let head xs = match xs with [] -> None | x :: _ -> Some x

let tail xs = match xs with [] -> None | _ :: rest -> Some rest
