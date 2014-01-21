open Std

let rec find_structure md =
  match md.Typedtree.mod_desc with
  | Typedtree.Tmod_structure _ -> Some md
  | Typedtree.Tmod_functor (_,_,_,md) -> find_structure md
  | Typedtree.Tmod_constraint (md,_,_,_) -> Some md
  | _ -> None

module P = struct
  open Raw_parser

  type st = Extension.set

  type t = {
    snapshot: Btype.snapshot;
    env: Env.t;
    structures: Typedtree.structure list;
  }

  let empty st =
    let env = Env.initial in
    let env = Env.open_pers_signature "Pervasives" env in
    let env = Extension.register st env in
    { snapshot = Btype.snapshot (); env; structures = [] }

  let validate _ t = Btype.is_valid t.snapshot

  let frame _ f t =
    let mkeval e = {
      Parsetree. pstr_desc = Parsetree.Pstr_eval e;
      pstr_loc = e.Parsetree.pexp_loc;
    } in
    let case =
      match Merlin_parser.value f with
      | Terminal _ | Bottom -> `none
      | Nonterminal nt ->
      match nt with
      | NT'structure str | NT'structure_tail str | NT'structure_item str ->
        `str str
      | NT'top_expr e | NT'strict_binding e | NT'simple_expr e | NT'seq_expr e
      | NT'opt_default (Some e) | NT'fun_def e | NT'fun_binding e | NT'expr e
      | NT'match_action e | NT'labeled_simple_expr (_,e) | NT'label_ident (_,e)
      | NT'label_expr (_,e) ->
        `str [mkeval e]
      | NT'expr_semi_list el | NT'expr_comma_opt_list el
      | NT'expr_comma_list el  ->
        `str (List.map ~f:mkeval el)
      | NT'module_expr pmod | NT'module_binding pmod ->
        `md pmod
      | NT'signature_item sg ->
        `sg sg
      | NT'signature sg ->
        `sg (List.rev sg)
      | NT'module_functor_arg (id,mty) ->
        `fmd (id,mty)
      | _ -> `none
    in
    match case with
    | `none -> t
    | _ as case ->
      Btype.backtrack t.snapshot;
      let env, structures =
        match case with
        | `str str ->
          let structures,_,env = Typemod.type_structure t.env str Location.none in
          env, structures :: t.structures
        | `sg sg ->
          let sg = Typemod.transl_signature t.env sg in
          let sg = sg.Typedtree.sig_type in
          Env.add_signature sg t.env, t.structures
        | `md pmod ->
          let tymod = Typemod.type_module t.env pmod in
          begin match find_structure tymod with
            | None -> t.env
            | Some md -> md.Typedtree.mod_env
          end, t.structures
        | `fmd (id,mty) ->
          let mexpr = Parsetree.Pmod_structure [] in
          let mexpr = { Parsetree. pmod_desc = mexpr; pmod_loc = Location.none } in
          let mexpr = Parsetree.Pmod_functor (id, mty, mexpr) in
          let mexpr = { Parsetree. pmod_desc = mexpr; pmod_loc = Location.none } in
          let tymod = Typemod.type_module t.env mexpr in
          begin match find_structure tymod with
            | None -> t.env
            | Some md -> md.Typedtree.mod_env
          end, t.structures
        | `none -> t.env, t.structures
      in
      {env; structures; snapshot = Btype.snapshot ()}

  let delta st f t ~old:_ = frame st f t
end

module I = Merlin_parser.Integrate (P)

type t = {
  btype_cache: Btype.cache;
  env_cache: Env.cache;
  st : Extension.set;
  t : I.t;
}

let fresh extensions =
  let btype_cache = Btype.new_cache () in
  let env_cache = Env.new_cache () in
  Btype.set_cache btype_cache;
  Env.set_cache env_cache;
  {
    btype_cache; env_cache;
    st = extensions; t = I.empty extensions;
  }

let update parser t =
  Btype.set_cache t.btype_cache;
  Env.set_cache t.env_cache;
  let t' = I.update' t.st parser t.t in
  {t with t = t'}

let env t = (I.value t.t).P.env
let structures t = (I.value t.t).P.structures
