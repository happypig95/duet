(** Operations on exponential polynomials. Exponential-polynomials are
   expressions of the form [E ::= x | lambda | lambda^x | E*E | E+E]
   where [lambda] is a rational *)
open Syntax

type t

val pp : Format.formatter -> t -> unit
val show : t -> string

val equal : t -> t -> bool

val add : t -> t -> t
val mul : t -> t -> t

val negate : t -> t

val zero : t
val one : t

val of_polynomial : Polynomial.QQX.t -> t

val of_exponential : QQ.t -> t

val scalar : QQ.t -> t

(** [compose_left_affine f a b] computes the function [lambda x. f (ax + b)] *)
val compose_left_affine : t -> int -> int -> t

(** [summation f] computes an exponential-polynomial [g] such that [g(n) = sum_{i=0}^n f(i)]. *)
val summation : t -> t

(** [solve_rec lambda g] computes an exponential-polynomial [g] such that
    {ul
      {- g(0) = f(0) }
      {- g(n) = lambda*g(n-1) + f(n) }} *)
val solve_rec : QQ.t -> t -> t

(** [term_of srk t f] computes a term representing [f(t)]. *)
val term_of : ('a context) -> 'a term -> t -> 'a term
