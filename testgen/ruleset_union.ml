(**
 * Copyright (c) 2013-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the "flow" directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *
 *)

module S = Ast.Statement;;
module E = Ast.Expression;;
module T = Ast.Type;;
module P = Ast.Pattern;;
module Utils = Flowtestgen_utils;;
module FRandom = Utils.FRandom;;

(* ESSENTIAL: Syntax type and related functions *)
module Syntax = Syntax_base;;
open Ruleset_base;;

class ruleset_union (depth : int) = object(self)
  inherit Ruleset_base.ruleset_base depth

  method! weak_assert b = self#backtrack_on_false b

  (* check t1 <: t2 *)
  method! is_subtype (t1 : T.t') (t2 : T.t') : bool =
    match t1, t2 with
    | (t, T.Union ((_, tu1), (_, tu2), tlist)) ->  (* t should be one of the branches of Union *)
      List.mem t (tu1 :: tu2 :: (List.map snd tlist))
    | T.Object o1, T.Object o2 -> self#is_subtype_obj o1 o2
    | T.Function f1, T.Function f2 -> self#is_subtype_func f1 f2
    | _ when t1 = t2 -> true
    | _ -> false

  (* Using a loose form of subtyping from ruleset_depth, so we can allow
    passing { p : 3 } to a function that expects { p : number | string }.
    In general this is unsound, and Flow allows this only in certain
    situations.
   *)
  method! is_subtype_obj (o1 : T.Object.t) (o2 : T.Object.t) =
    let get_prop_set (o : T.Object.t) =
      let tbl = Hashtbl.create 1000 in
      let open T.Object.Property in
      List.iter (fun p -> match p with
          | T.Object.Property (_, {key = E.Object.Property.Identifier (_, name);
                                   value = Init (_, t);
                                   optional = _;
                                   static = _;
                                   _method = _;
                                   variance = _;}) -> Hashtbl.add tbl name t
          | _ -> ()) T.Object.(o.properties);
      tbl in
    let s1 = get_prop_set o1 in
    let s2 = get_prop_set o2 in
    let subtype = ref true in
    (* check non optional properties *)
    Hashtbl.iter (fun n t ->
        (* Shouldn't use call is_subtyping recursivingly. We should
           use equality to limit depth subtyping *)
        if (not (Hashtbl.mem s1 n)) || (not (self#is_subtype (Hashtbl.find s1 n) t)) then
          subtype := false) s2;
    !subtype

  (* A helper funtions for wrapping an expression and a type
     into an object for mutation and expose type errors. *)
  method wrap_in_obj (expr : E.t') (etype : T.t') : (E.t' * T.t') =
    let pname = "p_0" in
    let obj_expr =
      let prop =
        let open E.Object.Property in
        E.Object.Property (Loc.none, {key = Identifier (Loc.none, pname);
                    value = Init (Loc.none, expr);
                    _method = false;
                    shorthand = false}) in
      let properties = [prop] in
      E.Object.(E.Object {properties}) in
    let obj_type =
      let open T.Object.Property in
      let prop_type =
        T.Object.Property (Loc.none, {key = E.Object.Property.Identifier (Loc.none, pname);
                                      value = Init (Loc.none, etype);
                                      optional = false;
                                      static = false;
                                      _method = false;
                                      variance = None;}) in
      T.Object.(T.Object {exact = false; properties = [prop_type]}) in
      obj_expr, obj_type

  (* A rule for generating object literals *)
  method! rule_obj_lit (env : env_t) : (Syntax.t * env_t) =

    (* a helper function for generating expression for object
       properties *)
    let rec gen_expr_list
        (count : int)
        (limit : int)
        (result : (E.t' * T.t') list) : (E.t' * T.t') list =
      if count = limit then result
      else
        let expr = self#choose count (fun () -> self#require_expr env) in
        let ep = match expr with
          | Expr (e, t) -> (e, t)
          | _ -> failwith "This has to be an expression" in

        (* we don't want functions to be properties of an object *)
        self#backtrack_on_false (match snd ep with
            | T.Function _ -> false
            | _ -> true);
        gen_expr_list (count + 1) limit (ep :: result) in

    (* We are getting at most 2 properties *)
    let elist = gen_expr_list 0 ((FRandom.rint 2) + 1) [] in
    let props =
      let count = ref 0 in
      let mk_prop () =
        let r = "p_" ^ (string_of_int !count) in
        count := !count + 1;
        r in
      List.map (fun e -> mk_prop (), e) elist in

    (* get the literal syntax and its type *)
    let lit = Syntax.mk_obj_lit props in
    let lit_expr = (match lit with
         | Syntax.Expr e -> e
         | _ -> failwith "[rule_obj_lit] Literal has to be an expr") in
    let ret_type =
      let prop_types =
        List.map (fun e ->
            let open T.Object.Property in
            T.Object.Property (Loc.none, {key = E.Object.Property.Identifier (Loc.none, fst e);
                                          value = Init (Loc.none, snd (snd e));
                                          optional = false;
                                          static = false;
                                          _method = false;
                                          variance = None})) props in
      let open T.Object in
      T.Object {exact = false; properties = prop_types} in
    (*
    (* Randomly wrap them into an object *)
    let lit_expr, ret_type = match FRandom.rbool () with
      | true -> self#wrap_in_obj lit_expr ret_type
      | false -> lit_expr, ret_type in
    *)

    let new_env =
      self#add_binding
        env
        (Expr (lit_expr, ret_type)) in
    let new_env = self#add_binding new_env (Type ret_type) in
    lit, new_env

  (* Rule for declaring a variable with init and type annotation *)
  method! rule_vardecl_with_type (env : env_t) : (Syntax.t * env_t) =
    (* require an expression from the environment *)
    let rhs = self#choose 0 (fun () -> self#require_expr env) in
    let rhs_expr, rhs_type = match rhs with
        | Expr (e, t) -> e, t
        | _ -> failwith "This has to be an expression" in

    (* For fast search on depth-subtyping *)
    self#backtrack_on_false (match rhs_expr, rhs_type with
        | E.Identifier _, _ -> true
        | _, T.Object _ -> true
        | _ -> false);

    (* require a type from the environment.*)
    let vtype = self#choose 1 (fun () -> self#require_type env) in
    let vtype = match vtype with
      | Type t -> t
      | _ -> failwith "This has to a type" in

    (* assert the subtyping relationhips between the rhs and lhs *)
    self#weak_assert (self#is_subtype rhs_type vtype);
    let vname = Utils.mk_var () in
    let var_decl = Syntax.mk_vardecl ~etype:vtype vname rhs_expr in
    let new_env =
      self#add_binding
        env
        (Expr ((E.Identifier (Loc.none, vname)), vtype)) in
    let new_env = self#add_binding new_env (Type vtype) in
    var_decl, new_env


  (* A rule for adding object types *)
  method! rule_obj_type (env : env_t) : (Syntax.t * env_t) =
    (* a helper function for generating object property types *)
    let rec gen_type_list
        (count : int)
        (limit : int)
        (result : T.t' list) : T.t' list =
      if count = limit then result
      else
        let ptype = self#choose count (fun () -> self#require_type env) in
        let ptype = match ptype with
          | Type t -> t
          | _ -> failwith "This has to be a type" in
        gen_type_list (count + 1) limit (ptype :: result) in

    let prop_types = gen_type_list 0 ((FRandom.rint 2) + 1) [] in
    let props =
      let count = ref 0 in
      let mk_prop () =
        let r = "p_" ^ (string_of_int !count) in
        count := !count + 1;
        r in
      List.map (fun t -> mk_prop (), t) prop_types in

    let ret_type =
      let prop_types =
        List.map (fun p ->
            let open T.Object.Property in
            T.Object.Property (Loc.none, {key = E.Object.Property.Identifier (Loc.none, fst p);
                                          value = Init (Loc.none, snd p);
                                          optional = false;
                                          (* currently causing problems: FRandom.rbool (); *)
                                          static = false;
                                          _method = false;
                                          variance = None})) props in
      let open T.Object in
      T.Object {exact = false; properties = prop_types} in
    let new_env =
      self#add_binding env (Type ret_type) in
    Syntax.Empty, new_env


  (* A rule for adding primitive types *)
  method! rule_union_type (env : env_t) : (Syntax.t * env_t) =
    (* a helper function for generating object property types *)
    let rec gen_type_list
        (count : int)
        (limit : int)
        (result : T.t' list) : T.t' list =
      if count = limit then result
      else
        let ptype = self#choose count (fun () -> self#require_type env) in
        let ptype = match ptype with
          | Type t -> t
          | _ -> failwith "This has to be a type" in
        self#backtrack_on_false (not (List.mem ptype result));
        (* Do not pick the same type again! *)
        gen_type_list (count + 1) limit (ptype :: result) in

    let ret_type =
      let open Array in
      let tarray = (gen_type_list 0 2 []) |> of_list in (* fixed to 2 *)
      T.Union ((Loc.none, get tarray 0),
               (Loc.none, get tarray 1),
               (List.map
                  (fun (s) -> (Loc.none, s))
                  (to_list (sub tarray 2 ((length tarray) - 2))))) in
    let new_env =
      self#add_binding env (Type ret_type) in
    Syntax.Empty, new_env

  (* A rule for generating function definitions *)
  method! rule_func_mutate (env : env_t) : (Syntax.t * env_t) =
    let mk_func_type (ptype : T.t') (rtype : T.t') : T.t' =
      let param_type =
        (Loc.none, T.Function.Param.({name = None;
                                      typeAnnotation = (Loc.none, ptype);
                                      optional = false})) in
      let ret_type = (Loc.none, rtype) in

      T.Function.(T.Function {params = [param_type], None;
                              returnType = ret_type;
                              typeParameters = None}) in

    (* parameter type *)
    let param_type =
      match self#choose 0 (fun () -> self#require_type env) with
      | Type t -> t
      | _ -> failwith "has to be a type" in

    (* Printf.printf "Before: %s\n" (Flowtestgen_utils.string_of_type param_type); *)

    (* We need to ensure the parameter is an object for mutation *)
    self#backtrack_on_false (match param_type with
        | T.Object {T.Object.properties=p; _} ->
          (List.length p) = 1  &&  (* find object ty with one prop only *)
          let prop = List.hd p in
          (match prop with  (* and force that prop be a union *)
            | T.Object.Property (_, {T.Object.Property.value=v; _}) ->
                (match v with
                  | T.Object.Property.Init (_, T.Union _) -> true
                  | _ -> false )
            | _ -> false
            )
        | _ -> false);

    (* Printf.printf "After: %s\n" (Flowtestgen_utils.string_of_type param_type); *)

    (* We are assuming we only have one parameter for now *)
    let pname = "param_" ^ (string_of_int depth) in

    let prop = self#choose 1 (fun () -> self#require_prop param_type true) in
    let pexpr, ptype = match prop with
        | Expr (e, t) -> e, t
        | _ -> failwith "This has to be an expression" in

    (* get the expression on the rhs of the update *)
    let rhs = self#choose 2 (fun () -> self#require_expr env) in
    let rhs_expr, rhs_type = match rhs with
        | Expr (e, t) -> e, t
        | _ -> failwith "This has to be an expression" in

    (* Printf.printf "Before assert: pexpr=%s rhs_expr=%s\n"
      (Flowtestgen_utils.string_of_expr pexpr)
      (Flowtestgen_utils.string_of_expr rhs_expr); *)

    (* assert that type(rhs) <: type(prop) *)
    self#weak_assert (self#is_subtype rhs_type ptype);

    (* Printf.printf "After assert\n"; *)

    (* produce a write syntax *)
    let write =
      Syntax.mk_prop_write
        (Utils.string_of_expr (E.Identifier (Loc.none, pname)))
        (Utils.string_of_expr pexpr)
        rhs_expr in

    (* return expression and its type *)
    let func_return_type = T.Void in

    let fname = Utils.mk_func () in

    let func_def =
      Syntax.mk_func_def
        fname
        pname
        param_type
        [write]
        func_return_type in

    let ret_type = mk_func_type param_type func_return_type in
    let new_env =
      self#add_binding
        env
        (Expr ((E.Identifier (Loc.none, fname)), ret_type)) in
    let new_env = self#add_binding new_env (Type ret_type) in
    func_def, new_env

  method! get_all_rules () =
    [|self#rule_num_lit;
      self#rule_str_lit;
      self#rule_union_type;
      self#rule_obj_type;
      self#rule_obj_lit;
      self#rule_vardecl_with_type;
      self#rule_prop_update;
      self#rule_func_mutate;
      self#rule_func_call;
      self#rule_prop_read;
      self#rule_vardecl_with_type;
      self#rule_prop_update;
      self#rule_func_mutate;
      self#rule_func_call;
      self#rule_prop_read;
      |]
end

class ruleset_random_union (depth : int) = object
  inherit ruleset_union depth
  method! weak_assert b =
    if (not b) && ((FRandom.rint 20) > 0) then raise Engine.Fail
end
