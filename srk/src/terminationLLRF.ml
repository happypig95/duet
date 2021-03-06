open Abstract
open Syntax
open SrkApron
open Printf
open BatEnum
module Vec = Linear.QQVector
module Mat = Linear.QQMatrix
module NL = NestedLoops

include Log.Make(struct let name = "TerminationLLRF" end)

type analysis_result = ProvedToTerminate | Unknown

let pre_symbols tr_symbols =
  List.fold_left (fun set (s,_) ->
      Symbol.Set.add s set)
    Symbol.Set.empty
    tr_symbols

let post_symbols tr_symbols =
  List.fold_left (fun set (_,s') ->
      Symbol.Set.add s' set)
    Symbol.Set.empty
    tr_symbols

(* Map from pre-state vars to their post-state counterparts *)
let post_map tr_symbols =
  List.fold_left
    (fun map (sym, sym') -> Symbol.Map.add sym sym' map)
    Symbol.Map.empty
    tr_symbols

let get_polyhedron_of_formula srk f cs =
  let f = match Formula.destruct srk f with
    | `And xs -> xs
    | `Tru -> []
    | `Atom t -> [ f ]
    | _ -> failwith "formula is not convex polyhedron"
  in
  let ppp = Polyhedron.of_implicant ~admit:true cs f in
  let e = Polyhedron.enum ppp in
  BatList.of_enum e

let get_coeff_of_symbol srk cs vec symbol =
  (* Format.fprintf Format.std_formatter "\nExamining this vector:\n"; 
     CoordinateSystem.pp_vector cs Format.std_formatter vec; 
     Format.fprintf Format.std_formatter "\nLooking for id of symbol:\n"; 
     pp_symbol srk Format.std_formatter symbol;   *)
  try 
    let tid = CoordinateSystem.cs_term_id cs (`App (symbol, [])) in
    Vec.coeff tid vec
  with Not_found -> QQ.zero

let build_system_of_ineq_for_non_inc srk cs ineqs dx_list x_list coeff_x_list coeff_x_set =
  (* first create the lambda symbols for each inequality *)
  let lambdas, f_with_non_neg_lambdas = 
    BatList.fold_righti
      (fun i ineq (lambdas, f) ->
         let lambda_i_name = String.concat "_" ["lambda"; string_of_int i] in
         let lambda_i = mk_const srk (mk_symbol srk ~name:lambda_i_name `TyReal) in
         match ineq with
         | `LeqZero t ->
           begin
             let newf = mk_and srk [mk_leq srk (mk_zero srk) lambda_i;  f] in
             (List.cons (lambda_i, lambda_i) lambdas, newf)
           end
         | `LtZero t -> failwith "expecting non-strict ineqs"
         | `EqZero t -> 
           begin
             let lambda_ip_name = String.concat "_" ["lambda"; "neg"; string_of_int i] in
             let lambda_ip = mk_const srk (mk_symbol srk ~name:lambda_ip_name `TyReal) in
             let newf1 = mk_and srk [mk_leq srk (mk_zero srk) lambda_i; f] in
             let newf2 = mk_and srk [mk_leq srk (mk_zero srk) lambda_ip; newf1] in
             (List.cons (lambda_i, lambda_ip) lambdas, newf2)
           end
      )
      ineqs
      ([], mk_true srk)
  in
  (* then add the coefficient constraints to the system *)
  let answer =
    BatList.fold_lefti
      (fun formulas i sym -> 
         (* let orig_sym = BatList.nth x_list i in *)
         let full_rhs =
           BatList.fold_lefti 
             (fun rhs i ineq ->
                match ineq with
                | `LeqZero t ->
                  begin
                    let lambda_i, _ = List.nth lambdas i in
                    let coeff = get_coeff_of_symbol srk cs t sym in
                    mk_add srk [rhs; mk_mul srk [lambda_i; mk_real srk coeff] ]
                  end
                | `LtZero t -> failwith "expecting non-strict ineqs"
                | `EqZero t -> 
                  begin
                    let coeff = get_coeff_of_symbol srk cs t sym in
                    let lambda_i, lambda_ip = List.nth lambdas i in
                    mk_add srk [rhs; 
                                mk_mul srk [lambda_i; mk_real srk coeff];
                                mk_mul srk [lambda_ip; mk_neg srk (mk_real srk coeff)] ]
                  end
             )
             (mk_zero srk)
             ineqs
         in
         let coeff_sym = List.nth coeff_x_list i in
         (* let coeff_sym = mk_symbol srk ~name:(String.concat "_" ["coeff"; show_symbol srk orig_sym]) `TyReal in *)
         let equ_for_this_var = mk_eq srk (mk_const srk coeff_sym) full_rhs in
         mk_and srk [ equ_for_this_var ; formulas]
      )
      f_with_non_neg_lambdas
      dx_list
  in
  logf "\nformula of lambdas on non-inc:\n%s\n\n" (Formula.show srk answer);
  (* finally add the constant constraints on lambdas *)
  let formula_with_const_constraints = 
    let rhs =
      BatList.fold_lefti
        (fun term i ineq ->
           match ineq with
           | `LeqZero t ->
             begin
               let c = Vec.coeff CoordinateSystem.const_id t in
               (* Format.fprintf Format.std_formatter "\nExamining this vector:\n";  *)
               CoordinateSystem.pp_vector cs Format.std_formatter t; 
               QQ.pp Format.std_formatter c;
               let lambda_i, _ = List.nth lambdas i in
               mk_add srk [mk_mul srk [mk_real srk c; lambda_i]; term]
             end
           | `LtZero t -> failwith "expecting non-strict ineqs"
           | `EqZero t -> 
             begin
               (* logf "did not expect this\n"; *)
               let c = Vec.coeff CoordinateSystem.const_id t in
               let lambda_i, lambda_ip = List.nth lambdas i in
               mk_add srk [mk_mul srk [mk_real srk c; lambda_i]; 
                           mk_mul srk [mk_neg srk (mk_real srk c); lambda_ip]; term]
             end
        )
        (mk_zero srk)
        ineqs
    in
    mk_and srk [answer; mk_leq srk (mk_zero srk) rhs]
  in
  logf "\nfinal formula for non-inc:\n%s\n\n" (Formula.show srk formula_with_const_constraints);
  let polka = Polka.manager_alloc_strict () in
  let f = rewrite srk ~down:(nnf_rewriter srk) formula_with_const_constraints in
  let property_of_formula =
    let exists x = Symbol.Set.mem x coeff_x_set in
    Abstract.abstract ~exists:exists srk polka f
  in
  let resulting_formula = SrkApron.formula_of_property property_of_formula in
  logf "\n non-inc cone:\n%s\n\n" (Formula.show srk resulting_formula);
  property_of_formula

let compute_non_inc_term_cone srk formula dx_list x_list dx_set coeff_x_list coeff_x_set =
  let polka = Polka.manager_alloc_strict () in
  let f = rewrite srk ~down:(nnf_rewriter srk) formula in
  let property_of_dx =
    let exists x = Symbol.Set.mem x dx_set in
    Abstract.abstract ~exists:exists srk polka f
  in
  let formula_of_dx = SrkApron.formula_of_property property_of_dx in
  logf "\nformula on dx:\n%s\n\n" (Formula.show srk formula_of_dx);
  let cs = CoordinateSystem.mk_empty srk in
  let ineqs = get_polyhedron_of_formula srk formula_of_dx cs in
  let non_inc_cone = build_system_of_ineq_for_non_inc srk cs ineqs dx_list x_list coeff_x_list coeff_x_set in
  non_inc_cone, cs

let build_system_of_ineq_for_lb_terms srk cs ineqs x_list coeff_x_list coeff_x_set =
  (* first create the lambda symbols for each inequality *)
  let lambdas, f_with_non_neg_lambdas = 
    BatList.fold_righti
      (fun i ineq (lambdas, f) ->
         let lambda_i_name = String.concat "_" ["lambda"; string_of_int i] in
         let lambda_i = mk_const srk (mk_symbol srk ~name:lambda_i_name `TyReal) in
         match ineq with
         | `LeqZero t ->
           begin
             let newf = mk_and srk [mk_leq srk (mk_zero srk) lambda_i;  f] in
             (List.cons (lambda_i, lambda_i) lambdas, newf)
           end
         | `LtZero t -> failwith "expecting non-strict ineqs"
         | `EqZero t -> 
           begin
             let lambda_ip_name = String.concat "_" ["lambda"; "neg"; string_of_int i] in
             let lambda_ip = mk_const srk (mk_symbol srk ~name:lambda_ip_name `TyReal) in
             let newf1 = mk_and srk [mk_leq srk (mk_zero srk) lambda_i; f] in
             let newf2 = mk_and srk [mk_leq srk (mk_zero srk) lambda_ip; newf1] in
             (List.cons (lambda_i, lambda_ip) lambdas, newf2)
           end
      )
      ineqs
      ([], mk_true srk)
  in
  (* then add the coefficient constraints to the system *)
  let answer =
    BatList.fold_lefti
      (fun formulas i sym -> 
         (* let orig_sym = BatList.nth x_list i in *)
         let full_rhs =
           BatList.fold_lefti 
             (fun rhs i ineq ->
                match ineq with
                | `LeqZero t ->
                  begin
                    let lambda_i, _ = List.nth lambdas i in
                    let coeff = QQ.negate (get_coeff_of_symbol srk cs t sym) in
                    mk_add srk [rhs; mk_mul srk [lambda_i; mk_real srk coeff] ]
                  end
                | `LtZero t -> failwith "expecting non-strict ineqs"
                | `EqZero t -> 
                  begin
                    let coeff = QQ.negate (get_coeff_of_symbol srk cs t sym) in
                    let lambda_i, lambda_ip = List.nth lambdas i in
                    mk_add srk [rhs; 
                                mk_mul srk [lambda_i; mk_real srk coeff];
                                mk_mul srk [lambda_ip; mk_neg srk (mk_real srk coeff)] ]
                  end
             )
             (mk_zero srk)
             ineqs
         in
         let coeff_sym = List.nth coeff_x_list i in
         let equ_for_this_var = mk_eq srk (mk_const srk coeff_sym) full_rhs in
         mk_and srk [ equ_for_this_var ; formulas]
      )
      f_with_non_neg_lambdas
      x_list
  in
  logf "\nformula of lambdas for lb:\n%s\n\n" (Formula.show srk answer);
  (* logf "\nfinal formula for lower-bounded:\n%s\n\n" (Formula.show srk answer); *)
  let polka = Polka.manager_alloc_strict () in
  let f = rewrite srk ~down:(nnf_rewriter srk) answer in
  let property_of_formula =
    let exists x = Symbol.Set.mem x coeff_x_set in
    Abstract.abstract ~exists:exists srk polka f
  in
  let resulting_formula = SrkApron.formula_of_property property_of_formula in
  logf "\nlower-bounded cone:\n%s\n\n" (Formula.show srk resulting_formula);
  property_of_formula

let compute_lower_bound_term_cone srk cs formula x_list x_set coeff_x_list coeff_x_set =
  let polka = Polka.manager_alloc_strict () in
  let f = rewrite srk ~down:(nnf_rewriter srk) formula in
  let property_of_dx =
    let exists x = Symbol.Set.mem x x_set in
    Abstract.abstract ~exists:exists srk polka f
  in
  let formula_of_lbx = SrkApron.formula_of_property property_of_dx in
  logf "\nformula of lower-bounded terms:\n%s\n\n" (Formula.show srk formula_of_lbx);
  let ineqs = get_polyhedron_of_formula srk formula_of_lbx cs in
  let non_inc_cone = build_system_of_ineq_for_lb_terms srk cs ineqs x_list coeff_x_list coeff_x_set in
  non_inc_cone


let rec find_quasi_rf depth srk f qrfs x_list xp_list dx_list x_set xp_set dx_set x_to_dx dx_to_x coeff_x_list coeff_x_set =
  (* let (qf, phi) = Quantifier.normalize srk f  in
     if List.exists (fun (q, _) -> q = `Forall) qf then
     failwith "universal quantification not supported";
     let exists v =
     not (List.exists (fun (_, x) -> x = v) qf)
     in
     let polka = Polka.manager_alloc_strict () in
     let ff = Abstract.abstract ~exists:exists srk polka phi in
     if (SrkApron.is_bottom ff) then
     if depth = 1 then
      (true, depth-1, f, qrfs) else
      (false, depth-1, f, qrfs)
     else
     let formula = SrkApron.formula_of_property ff in *)
  let formula = f in
  (* logf "\n original polyhedron transition formula:\n%s\n" (Formula.show srk formula); *)
  let non_inc_term_cone, cs = compute_non_inc_term_cone srk formula dx_list x_list dx_set coeff_x_list coeff_x_set in
  if (SrkApron.is_bottom non_inc_term_cone) then 
    begin
      logf ~attributes:[`Bold; `Red] "non-increasing term cone is empty, fail";
      (false, depth-1, formula, qrfs) 
    end
  else
    let lb_term_cone = compute_lower_bound_term_cone srk cs formula x_list x_set coeff_x_list coeff_x_set in
    if (SrkApron.is_bottom lb_term_cone) then 
      begin
        logf ~attributes:[`Bold; `Red] "bounded-term cone is empty, fail";
        (false, depth-1,formula, qrfs) 
      end
    else

      let c = SrkApron.meet non_inc_term_cone lb_term_cone in
      (* let c = Abstract.abstract srk polka intersection_cone in *)
      if (SrkApron.is_bottom c) then
        begin
          logf ~attributes:[`Bold; `Red] "intersection of two cones is empty, fail";
          (false, depth-1, formula, qrfs) 
        end
      else
        let gens = SrkApron.generators c in
        let coeff_all_zero = not (BatList.exists (fun (generator, typ) -> match typ with | `Ray -> true | _ -> false) gens) in
        if coeff_all_zero then 
          begin
            logf ~attributes:[`Bold; `Red] "only all zero quasi ranking function exists at this level, fail";
            (false, depth-1, formula, qrfs) 
          end
        else
          let resulting_cone = SrkApron.formula_of_property c in
          logf "\ncone of qrfs:\n%s\n\n" (Formula.show srk resulting_cone);

          let get_orig_or_primed_expr_of_gen generator xs =
            let term = Linear.term_of_vec srk (
                fun d -> 
                  let coeffSym = symbol_of_int d in 
                  let origSym = List.nth 
                      xs 
                      (let ind, _ = BatList.findi (fun i a -> a = coeffSym) coeff_x_list in ind)
                  in
                  mk_const srk origSym
              )
                generator in
            term
          in
          let new_qrfs = 
            (BatList.map 
               (fun (generator, typ) ->
                  get_orig_or_primed_expr_of_gen generator x_list
               )
               gens) :: qrfs
          in
          let new_constraints = 
            BatList.map 
              (fun (generator, typ) ->
                 let pre_trans_term = get_orig_or_primed_expr_of_gen generator x_list in
                 let post_trans_term = get_orig_or_primed_expr_of_gen generator xp_list in
                 let equ = mk_eq srk post_trans_term pre_trans_term in
                 (* logf "%a" (Formula.pp srk) equ; *)
                 equ
              )
              gens
          in
          let restricted_formula = mk_and srk (f :: new_constraints) in
          logf "\nrestricted formula for next iter:\n%s\n\n" (Formula.show srk restricted_formula);
          match Smt.get_model srk restricted_formula with
          | `Sat interp -> 
            logf ~attributes:[`Bold; `Yellow] "\n\n\nTransition formula SAT, try to synthesize next depth\n\n";
            find_quasi_rf (depth+1) srk restricted_formula new_qrfs x_list xp_list dx_list x_set xp_set dx_set x_to_dx dx_to_x coeff_x_list coeff_x_set
          | `Unknown -> failwith "SMT solver should not return unknown"
          | `Unsat -> (logf ~attributes:[`Bold; `Green] "Transition formula UNSAT, done"); (true, depth, formula, qrfs)

let add_diff_terms_to_formula srk f x_xp =
  List.fold_right
    (fun (x, xp) (f, dx_list, dx_sym_set, x_to_dx, dx_to_x) -> 
       let dname = String.concat "" ["d_"; show_symbol srk x] in
       let cx = mk_const srk x in
       let cxp = mk_const srk xp in 
       let diff = mk_sub srk cxp cx in
       let dx_sym = mk_symbol srk ~name:dname `TyInt in
       let dx = mk_const srk dx_sym in
       let f_with_dx = mk_and srk [f ; mk_eq srk dx diff] in
       (f_with_dx, 
        List.cons dx_sym dx_list,
        Symbol.Set.add dx_sym dx_sym_set, 
        Symbol.Map.add x dx_sym x_to_dx, 
        Symbol.Map.add dx_sym x dx_to_x)
    )
    x_xp
    (f, [], Symbol.Set.empty, Symbol.Map.empty, Symbol.Map.empty)


let prove_LLRF_termination srk tto_transition_formula loop =
  let _, body = loop in
  let x_xp, orig_formula = tto_transition_formula body [] in
  let body_formula = Nonlinear.linearize srk orig_formula in
  match Smt.get_model srk body_formula with
  | `Sat interp -> 
    (* logf ~attributes:[`Bold; `Green] "\n\n\nTransition formula SAT\n\n"; *)
    let x_list = List.fold_right (fun (sp, spp) l -> sp :: l ) x_xp [] in
    let xp_list = List.fold_right (fun (sp, spp) l -> spp :: l ) x_xp [] in
    let coeff_x_list, coeff_x_set = 
      List.fold_right 
        (fun x (l, s) ->
           let coeff_sym = mk_symbol srk ~name:(String.concat "_" ["coeff"; show_symbol srk x]) `TyReal in
           (coeff_sym :: l, Symbol.Set.add coeff_sym s)
        )
        x_list
        ([], Symbol.Set.empty)
    in
    let x_set = pre_symbols x_xp in
    let xp_set = post_symbols x_xp in
    let f_with_dx, dx_list, dx_set, x_to_dx, dx_to_x = add_diff_terms_to_formula srk body_formula x_xp in
    logf "\nformula with dx:\n%s\n\n" (Formula.show srk f_with_dx);
    let (success, dep, formula, qrfs) = find_quasi_rf 1 srk f_with_dx [] x_list xp_list dx_list x_set xp_set dx_set x_to_dx dx_to_x coeff_x_list coeff_x_set in
    logf "\nSuccess: %s\nDepth: %s\n" (string_of_bool success) (string_of_int dep);
    if success then ProvedToTerminate else Unknown
  | `Unknown -> logf "SMT solver should not return unknown for QRA formulas"; Unknown
  | `Unsat -> (logf ~attributes:[`Bold; `Yellow] "Transition formula UNSAT, done"); ProvedToTerminate
