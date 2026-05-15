(* Fixed-point DeFi quote smoke test.

   The example uses the bundled Fixed/Amount helpers to compute a simple
   constant-product AMM quote with a 30 bps input fee. It returns 0 after the
   assertions pass so the same file is usable as a Solana BPF smoke program. *)

external log_message : string -> unit = "sol_log_"
external log_values : int -> int -> int -> int -> int -> unit = "sol_log_64_"

let quote_constant_product input_reserve output_reserve input_amount fee_bps =
  let fee = Amount.fee_bps input_amount fee_bps in
  let net_input = input_amount - fee in
  (output_reserve * net_input) / (input_reserve + net_input)

let quote_linear input_amount price = Amount.apply_rate input_amount price

let entrypoint _input =
  let _ = log_message "fixed amm quote: starting" in
  let input_reserve = 1000000 in
  let output_reserve = 2000000 in
  let input_amount = 10000 in
  let fee_bps = 30 in
  let fee = Amount.fee_bps input_amount fee_bps in
  let net_input = Amount.discount_bps input_amount fee_bps in
  let spot_price = Fixed.ratio output_reserve input_reserve in
  let linear_quote = quote_linear net_input spot_price in
  let amm_quote =
    quote_constant_product input_reserve output_reserve input_amount fee_bps
  in
  let _ = log_values fee net_input (Fixed.to_scaled spot_price) linear_quote amm_quote in
  assert (fee = 30);
  assert (net_input = 9970);
  assert (Fixed.to_scaled spot_price = 2000000);
  assert (linear_quote = 19940);
  assert (amm_quote = 19743);
  0
