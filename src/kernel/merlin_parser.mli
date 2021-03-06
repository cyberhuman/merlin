(* {{{ COPYING *(

  This file is part of Merlin, an helper for ocaml editors

  Copyright (C) 2013 - 2014  Frédéric Bour  <frederic.bour(_)lakaban.net>
                             Thomas Refis  <refis.thomas(_)gmail.com>
                             Simon Castellan  <simon.castellan(_)iuwt.fr>

  Permission is hereby granted, free of charge, to any person obtaining a
  copy of this software and associated documentation files (the "Software"),
  to deal in the Software without restriction, including without limitation the
  rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
  sell copies of the Software, and to permit persons to whom the Software is
  furnished to do so, subject to the following conditions:

  The above copyright notice and this permission notice shall be included in
  all copies or substantial portions of the Software.

  The Software is provided "as is", without warranty of any kind, express or
  implied, including but not limited to the warranties of merchantability,
  fitness for a particular purpose and noninfringement. In no event shall
  the authors or copyright holders be liable for any claim, damages or other
  liability, whether in an action of contract, tort or otherwise, arising
  from, out of or in connection with the software or the use or other dealings
  in the Software.

)* }}} *)

open Std

module Values : module type of Raw_parser_values

type t

(** Initialization *)

type state = Raw_parser.state

val implementation : state
val interface : state

val from : state -> Lexing.position * Raw_parser.token * Lexing.position -> t

(** Manipulation *)

(* Feed new token *)
val feed : Lexing.position * Raw_parser.token * Lexing.position
        -> t
        -> [ `Accept of Raw_parser.symbol | `Step of t
           | `Reject of t ]

(* Dump internal state for debugging purpose *)
val dump : t -> Std.json

(* Location of top frame in stack *)
(* for recovery: approximate position of last correct construction *)
val get_location : ?pop:int -> t -> Location.t
val get_guide : ?pop:int -> t -> Lexing.position
val get_lr0_state : t -> int
val get_lr1_state : t -> int
val get_lr0_states : t -> int List.Lazy.t
val get_lr1_states : t -> int List.Lazy.t
val last_token : t -> Raw_parser.token Location.loc

(* Just remove the state on top of the stack *)
val pop : t -> t option

(* Try to reduce the state on top of the stack *)
type termination
val termination : termination
val recover : ?endp:Lexing.position
  -> termination -> t
  -> (termination * (int * t Location.loc)) option

(* Access to underlying raw parser *)
val to_step : t -> Raw_parser.feed Raw_parser.parser


(** Stack inspection *)
type frame

val stack : t -> frame

module Frame : sig
  val depth : frame -> int

  val value : frame -> Raw_parser.symbol
  val location : ?pop:int -> frame -> Location.t
  val eq    : frame -> frame -> bool
  val next  : ?n:int -> frame -> frame option

  val lr1_state : frame -> int
  val lr0_state : frame -> int

  (* Ease pattern matching on parser stack *)
  type destruct = D of Raw_parser.symbol * destruct lazy_t
  val destruct: frame -> destruct
end

(** Stack integration, incrementally compute metric over each frame *)

type parser = t

module Integrate
    (P : sig

       (* Type of the value computed at each frame *)
       type t

       (* User-defined state *)
       type st

       (* Generate an initial value, from an empty stack *)
       val empty : st -> t

       (* Fold function updating a value from a frame *)
       val frame : st -> frame -> t -> t

       (* (REMOVE?) Special case, specific fold function called
          at the point where two stacks start diverging
       *)
       val delta : st -> frame -> t -> old:(t * frame) -> t

       (* Check if an intermediate result is still valid.
          If this function returns [false], this value will not be reused
          in the incremental computation.
       *)
       val validate : st -> t -> bool

       (* [evict st t] is called when [t] is dropped out of the value stack *)
       val evict : st -> t -> unit

     end) :
sig
  type t

  (* Return a fresh incremental computation from user-defined state *)
  val empty : P.st -> t

  (* Starting from a top frame, update incremental value while minimizing
     amount of computations. *)
  val update : P.st -> frame -> t -> t

  (* Same but starting from a parser *)
  val update' : P.st -> parser -> t -> t

  (* Observe the current value computed *)
  val value : t -> P.t

  (* Drop the stack frame at the top of the computation, if any *)
  val previous : t -> t option

  (* Change value at the top of stack *)
  val modify : (P.t -> P.t) -> t -> t
end

(** [find_marker] return the first frame that might be unsafe for the parser *)
val find_marker : t -> frame option

(** [has_marker ?diff t f] returns true iff f is still in t stack.
    If provided, [diff] is used to speed-up the search (amortized constant time),
    assuming that [diff] is the same parser as [t] with one more or one less
    token fed. *)
val has_marker : ?diff:(t * bool) -> t -> frame -> bool
