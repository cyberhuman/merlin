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
open Merlin_lib

let sources_path = Fluid.from (Misc.Path_list.of_list [])
let cmt_path     = Fluid.from (Misc.Path_list.of_list [])

let section = Logger.section "locate"
let debug_log x = Printf.ksprintf (Logger.debug section)  x

module Fallback = struct
  let fallback = ref `Nothing

  let get () = !fallback

  let set ~source loc =
    Logger.debugf section (fun fmt loc ->
      Format.fprintf fmt "Fallback.set %b" source;
      Location.print fmt loc
    ) loc ;
    fallback := if source then `ML loc else `MLI loc

  let reset () = fallback := `Nothing

  let is_set () = !fallback <> `Nothing
end

type filetype =
  | ML   of string
  | MLI  of string
  | CMT  of string
  | CMTI of string

module Preferences : sig
  val set : [ `ML | `MLI ] -> unit

  val cmt : string -> filetype

  val final : 'a -> [> `ML of 'a | `MLI of 'a ]
end = struct
  let prioritize_impl = ref true

  let set choice =
    prioritize_impl :=
      match choice with
      | `ML -> true
      | _ -> false

  let cmt file = if !prioritize_impl then CMT file else CMTI file

  let final file = if !prioritize_impl then `ML file else `MLI file
end

module File_switching : sig
  exception Can't_move

  val reset : unit -> unit

  val check_can_move : unit -> unit

  val move_to : ?digest:Digest.t -> string -> unit (* raises Can't_move *)

  val allow_movement : unit -> unit

  val where_am_i : unit -> string option

  val source_digest : unit -> Digest.t option
end = struct
  type t = {
    already_moved : bool ;
    last_file_visited : string option ;
    digest : Digest.t option ;
  }

  exception Can't_move

  let default =
    { already_moved = false ; last_file_visited = None ; digest = None }

  let state = ref default

  let reset () = state := default

  let check_can_move () =
    if !state.already_moved then raise Can't_move

  let move_to ?digest file =
    if !state.already_moved then raise Can't_move else
    debug_log "File_switching.move_to %s" file ;
    state := { already_moved = true ; last_file_visited = Some file ; digest }

  let allow_movement () =
    debug_log "File_switching.allow_movement" ;
    state := { !state with already_moved = false }

  let where_am_i () = !state.last_file_visited

  let source_digest () = !state.digest
end


module Utils = struct
  let info_log  x = Printf.ksprintf (Logger.info  section)  x

  let is_ghost { Location. loc_ghost } = loc_ghost = true

  let longident_is_qualified = function
    | Longident.Lident _ -> false
    | _ -> true

  let path_to_list p =
    let rec aux acc = function
      | Path.Pident id -> id.Ident.name :: acc
      | Path.Pdot (p, str, _) -> aux (str :: acc) p
      | _ -> assert false
    in
    aux [] p

  let file_path_to_mod_name f =
    let pref = Misc.chop_extensions f in
    String.capitalize (Filename.basename pref)

  exception File_not_found of filetype

  let filename_of_filetype = function ML name | MLI name | CMT name | CMTI name -> name
  let ext_of_filetype = function
    | ML _  -> ".ml"  | MLI _  -> ".mli"
    | CMT _ -> ".cmt" | CMTI _ -> ".cmti"

  (* Reuse the code of [Misc.find_in_path_uncap] but returns all the files
     matching, instead of the first one.
     This is only used when looking for ml files, not cmts. Indeed for cmts we
     know that the load path will only ever contain files with uniq names (in
     the presence of packed modules we refine the loadpath as we go); this in
     not the case for the "source path" however.
     We therefore get all matching files and use an heuristic at the call site
     to choose the appropriate file. *)
  let find_all_in_path_uncap ?(fallback="") path name =
    let has_fallback = fallback <> "" in
    List.map ~f:Misc.canonicalize_filename begin
      let acc = ref [] in
      let uname = String.uncapitalize name in
      let ufbck = String.uncapitalize fallback in
      let rec try_dir = function
        | List.Lazy.Nil -> !acc
        | List.Lazy.Cons (dir, rem) ->
            let fullname = Filename.concat dir name in
            let ufullname = Filename.concat dir uname in
            let ufallback = Filename.concat dir ufbck in
            if Sys.file_exists ufullname then acc := ufullname :: !acc
            else if Sys.file_exists fullname then acc := fullname :: !acc
            else if has_fallback && Sys.file_exists ufallback then
              acc := ufallback :: !acc
            else if has_fallback && Sys.file_exists fallback then
              acc := fallback :: !acc
            else
              () ;
            try_dir (Lazy.force rem)
      in try_dir (Misc.Path_list.to_list path)
    end

  let find_all_matches ?(with_fallback=false) file =
    let fname =
      Misc.chop_extension_if_any (filename_of_filetype file)
      ^ (ext_of_filetype file)
    in
    let fallback =
      if not with_fallback then "" else
      match file with
      | ML f   -> Misc.chop_extension_if_any f ^ ".mli"
      | MLI f  -> Misc.chop_extension_if_any f ^ ".ml"
      | _ -> assert false
    in
    let path = Fluid.get sources_path in
    find_all_in_path_uncap ~fallback path fname

  let find_file ?(with_fallback=false) file =
    let fname =
      Misc.chop_extension_if_any (filename_of_filetype file)
      ^ (ext_of_filetype file)
    in
    let fallback =
      if not with_fallback then "" else
      match file with
      | ML f   -> Misc.chop_extension_if_any f ^ ".mli"
      | MLI f  -> Misc.chop_extension_if_any f ^ ".ml"
      | CMT f  -> Misc.chop_extension_if_any f ^ ".cmti"
      | CMTI f -> Misc.chop_extension_if_any f ^ ".cmt"
    in
    try
      let path =
        match file with
        | ML  _ | MLI _  -> Fluid.get sources_path
        | CMT _ | CMTI _ -> Fluid.get cmt_path
      in
      Misc.find_in_path_uncap ~fallback path fname
    with Not_found ->
      raise (File_not_found file)

  let keep_suffix =
    let open Longident in
    let rec aux = function
      | Lident str ->
        if String.lowercase str <> str then
          Some (Lident str, false)
        else
          None
      | Ldot (t, str) ->
        if String.lowercase str <> str then
          match aux t with
          | None -> Some (Lident str, true)
          | Some (t, is_label) -> Some (Ldot (t, str), is_label)
        else
          None
      | t ->
        Some (t, false) (* don't know what to do here, probably best if I do nothing. *)
    in
    function
    | Lident s -> Lident s, false
    | Ldot (t, s) ->
      begin match aux t with
      | None -> Lident s, true
      | Some (t, is_label) -> Ldot (t, s), is_label
      end
    | otherwise -> otherwise, false
end

include Utils

type result = [
  | `Found of string option * Lexing.position
  | `Not_in_env of string
  | `File_not_found of string
  | `Not_found
]

type context = Type | Expr | Patt | Unknown
exception Context_mismatch

(* Remove top level indirections (i.e. Structure and Signature) and reverse
   their children so we start from the bottom of the file.
   We also remove everything appearing after [pos]: we don't want to consider
   things declared after the use point of what we are looking for. *)
let rec get_top_items ?pos browsable =
  let starts_before x =
    match pos with
    | None -> true
    | Some pos -> Lexing.compare_pos x.BrowseT.t_loc.Location.loc_start pos < 0
  in
  let ends_before x =
    match pos with
    | None -> true
    | Some pos -> Lexing.compare_pos x.BrowseT.t_loc.Location.loc_end pos < 0
  in
  List.concat_map (fun bt ->
    if not (starts_before bt) then [] else
    let open BrowseT in
    match bt.t_node with
    | Signature _
    | Structure _ ->
      let children = List.rev (Lazy.force bt.t_children) in
      if ends_before bt then children else get_top_items ?pos children
    | Signature_item _
    | Structure_item _  ->
      if ends_before bt then [ bt ] else
      let children = List.rev (Lazy.force bt.t_children) in
      get_top_items ?pos children
    | Module_binding _
    | Module_type_declaration _ ->
      (* N.B. we don't check [ends_before] here, because the fack that these are
       * not [Structure]/[Structure_item] (resp. sign) nodes means that they end
       * after [pos] and we should only consider their children. *)
      List.concat_map (Lazy.force bt.t_children) ~f:(fun bt ->
        match bt.t_node with
        | Module_expr _
        | Module_type _ ->
          (* FIXME: a bit too rough, [With_constraint] and
             [Module_type_constraint] nodes are ignored... *)
          let children = List.rev (Lazy.force bt.t_children) in
          get_top_items ?pos children
        | _ -> []
      )
    | _ -> []
  ) browsable

let repack = function
  | `Not_included -> None
  | `Mod_expr me  -> Some (BrowseT.Module_expr me)
  | `Mod_type mty -> Some (BrowseT.Module_type mty)

let rec check_item ~source modules =
  let get_loc ~name item rest =
    let ident_locs, is_included =
      let open Raw_compat in
      match item.BrowseT.t_node with
      | BrowseT.Structure_item item ->
        str_ident_locs item, get_mod_expr_if_included item
      | BrowseT.Signature_item item ->
        sig_ident_locs item, get_mod_type_if_included item
      | _ -> assert false
    in
    try
      let res = List.assoc name ident_locs in
      if source then `ML res else `MLI res
    with Not_found ->
      match repack (is_included ~name) with
      | None -> check_item ~source modules rest
      | Some thing ->
        info_log "one more include to follow..." ;
        Fallback.set ~source item.BrowseT.t_loc ;
        resolve_mod_alias ~source thing [ name ] rest
  in
  let get_on_track ~name item =
    match
      let open Raw_compat in
      match item.BrowseT.t_node with
      | BrowseT.Structure_item item ->
        repack (get_mod_expr_if_included ~name item),
        begin try
          let mbs = expose_module_binding item in
          let mb = List.find ~f:(fun mb -> Ident.name mb.Typedtree.mb_id = name) mbs in
          info_log "(get_on_track) %s is bound" name ;
          `Direct (BrowseT.Module_expr mb.Typedtree.mb_expr)
        with Not_found -> `Not_found end
      | BrowseT.Signature_item item ->
        repack (get_mod_type_if_included ~name item),
        begin try
          let mds = expose_module_declaration item in
          let md = List.find ~f:(fun md -> Ident.name md.Typedtree.md_id = name) mds in
          info_log "(get_on_track) %s is bound" name ;
          `Direct (BrowseT.Module_type md.Typedtree.md_type)
        with Not_found -> `Not_found end
      | _ -> assert false
    with
    | None, whatever -> whatever
    | Some thing, `Not_found ->
      info_log "(get_on_track) %s is included..." name ;
      `Included thing
    | _ -> assert false
  in
  function
  | [] ->
    info_log "%s not in current file..." (String.concat ~sep:"." modules) ;
    from_path modules
  | item :: rest ->
    match modules with
    | [] -> assert false
    | [ str_ident ] -> get_loc ~name:str_ident item rest
    | mod_name :: path ->
      match get_on_track ~name:mod_name item with
      | `Not_found   -> check_item ~source modules rest
      | `Direct me   ->
        Fallback.set ~source item.BrowseT.t_loc ;
        resolve_mod_alias ~source me path rest
      | `Included me ->
        Fallback.set ~source item.BrowseT.t_loc ;
        resolve_mod_alias ~source me modules rest

and browse_cmts ~root modules =
  let open Cmt_format in
  let cmt_infos = Cmt_cache.read root in
  info_log "inspecting %s" root ;
  File_switching.move_to ?digest:cmt_infos.cmt_source_digest root ;
  match
    match cmt_infos.cmt_annots with
    | Interface intf      -> `Sg intf, false
    | Implementation impl -> `Str impl, true
    | Packed (_, files)   -> `Pack files, true
    | _ ->
      (* We could try to work with partial cmt files, but it'd probably fail
       * most of the time so... *)
      `Not_found, true
  with
  | `Not_found, _ -> `Not_found
  | (`Str _ | `Sg _ as typedtree), source ->
    begin match modules with
    | [] ->
      (* we were looking for a module, we found the right file, we're happy *)
      let pos = Lexing.make_pos ~pos_fname:root (1, 0) in
      let loc = { Location. loc_start=pos ; loc_end=pos ; loc_ghost=false } in
      if source then `ML loc else `MLI loc
    | _ ->
      let browses   = Browse.of_typer_contents [ typedtree ] in
      let browsable = get_top_items browses in
      check_item ~source modules browsable
    end
  | `Pack files, _ ->
    begin match modules with
    | [] -> `Not_found
    | mod_name :: modules ->
      let file = 
        List.find files ~f:(fun s -> file_path_to_mod_name s = mod_name)
      in
      File_switching.allow_movement () ;
      debug_log "Saw packed module => erasing loadpath" ;
      let str_path_list =
        List.map cmt_infos.cmt_loadpath ~f:(function
          | "" ->
            (* That's the cwd at the time of the generation of the cmt, I'm
               guessing/hoping it will be the directory where we found it *)
            Filename.dirname root
          | x -> x
        )
      in
      let pl = Misc.Path_list.of_string_list_ref (ref str_path_list) in
      Fluid.let' cmt_path pl (fun () ->
        let root = find_file ~with_fallback:true (Preferences.cmt file) in
        browse_cmts ~root modules
      )
    end

and from_path path =
  File_switching.check_can_move () ;
  match path with
  | [] -> assert false
  | [ fname ] ->
    let pos = Lexing.make_pos ~pos_fname:fname (1, 0) in
    let loc = { Location. loc_start=pos ; loc_end=pos ; loc_ghost=true } in
    File_switching.move_to loc.Location.loc_start.Lexing.pos_fname ;
    Preferences.final loc
  | fname :: modules ->
    try
      let cmt_file = find_file ~with_fallback:true (Preferences.cmt fname) in
      browse_cmts ~root:cmt_file modules
    with File_not_found (CMT fname | CMTI fname) as exn ->
      info_log "failed to locate the cmt[i] of '%s'" fname ;
      raise exn

and resolve_mod_alias ~source node path rest =
  let direct, loc =
    match node with
    | BrowseT.Module_expr me  ->
      Raw_compat.remove_indir_me me, me.Typedtree.mod_loc
    | BrowseT.Module_type mty ->
      Raw_compat.remove_indir_mty mty, mty.Typedtree.mty_loc
    | _ -> assert false (* absurd *)
  in
  match direct with
  | `Alias path' ->
    File_switching.allow_movement () ;
    let full_path = (path_to_list path') @ path in
    check_item ~source full_path rest
  | `Sg _ | `Str _ as x ->
    let lst = get_top_items (Browse.of_typer_contents [ x ]) @ rest in
    check_item ~source path lst
  | `Functor msg ->
    info_log "stopping on functor%s" msg ;
    if source then `ML loc else `MLI loc
  | `Mod_type mod_type ->
    resolve_mod_alias ~source (BrowseT.Module_type mod_type) path rest
  | `Mod_expr mod_expr ->
    resolve_mod_alias ~source (BrowseT.Module_expr mod_expr) path rest
  | `Unpack ->
    (* FIXME: should we do something or stop here? *)
    info_log "found Tmod_unpack, expect random results." ;
    check_item ~source path rest

let path_and_loc_from_label desc env =
  let open Types in
  match desc.lbl_res.desc with
  | Tconstr (path, _, _) ->
    let typ_decl = Env.find_type path env in
    path, typ_decl.Types.type_loc
  | _ -> assert false

exception Not_in_env
exception Multiple_matches of string list

let finalize source loc =
  let fname = loc.Location.loc_start.Lexing.pos_fname in
  let with_fallback = loc.Location.loc_ghost in
  let mod_name = file_path_to_mod_name fname in
  let file = if source then ML mod_name else MLI mod_name in
  let full_path =
    match File_switching.where_am_i () with
    | None -> (* We have not moved, we don't want to return a filename *) None
    | Some s ->
      let dir = Filename.dirname s in
      debug_log "source fname = %s (in dir : %s)" fname dir ;
      match find_all_matches ~with_fallback file with
      | [] -> raise (File_not_found file)
      | [ x ] -> Some x
      | files ->
        try
          match File_switching.source_digest () with
          | None -> raise Not_found
          | Some digest ->
            debug_log "Trying to use digest to find the right source file" ;
            Some (List.find files ~f:(fun f -> Digest.file f = digest))
        with Not_found ->
          info_log "multiple files named %s exist in the source path, using \
                    heuristic to select the right one" fname ;
          let rev = String.reverse (Filename.concat dir fname) in
          let lst =
            List.map files ~f:(fun path ->
              let path' = String.reverse path in
              String.common_prefix_len rev path', path
            )
          in
          let lst =
            (* TODO: remove duplicates in [source_path] instead of using
              [sort_uniq] here. *)
            List.sort_uniq ~cmp:(fun ((i:int),s) ((j:int),t) ->
              let tmp = compare j i in
              if tmp <> 0 then tmp else
              compare s t
            ) lst
          in
          match lst with
          | (i1, s1) :: (i2, s2) :: _ when i1 = i2 ->
            raise (Multiple_matches files)
          | (_, s) :: _ -> Some s
          | _ -> assert false
  in
  `Found (full_path, loc.Location.loc_start)

let recover () =
  match Fallback.get () with
  | `Nothing -> assert false
  | `ML  loc -> finalize true loc
  | `MLI loc -> finalize false loc

let namespaces = function
  | Type        -> [ `Type ; `Constr ; `Mod ; `Modtype ; `Labels ; `Vals ]
  | Expr | Patt -> [ `Vals ; `Constr ; `Mod ; `Modtype ; `Labels ; `Type ]
  | Unknown     -> [ `Vals ; `Type ; `Constr ; `Mod ; `Modtype ; `Labels ]

exception Found of (Path.t * Location.t)

let lookup ctxt ident env =
  try
    List.iter (namespaces ctxt) ~f:(fun namespace ->
      try
        match namespace with
        | `Constr ->
          info_log "lookup in constructor namespace" ;
          let cstr_desc = Raw_compat.lookup_constructor ident env in
          raise (Found (Raw_compat.path_and_loc_of_cstr cstr_desc env))
        | `Mod ->
          info_log "lookup in module namespace" ;
          let path, _ = Raw_compat.lookup_module ident env in
          raise (Found (path, Location.symbol_gloc ()))
        | `Modtype ->
          info_log "lookup in module type namespace" ;
          let path, _ = Raw_compat.lookup_modtype ident env in
          raise (Found (path, Location.symbol_gloc ()))
        | `Type ->
          info_log "lookup in type namespace" ;
          let path, typ_decl = Env.lookup_type ident env in
          raise (Found (path, typ_decl.Types.type_loc))
        | `Vals ->
          info_log "lookup in value namespace" ;
          let path, val_desc = Env.lookup_value ident env in
          raise (Found (path, val_desc.Types.val_loc))
        | `Labels ->
          info_log "lookup in label namespace" ;
          let label_desc = Raw_compat.lookup_label ident env in
          raise (Found (path_and_loc_from_label label_desc env))
      with Not_found -> ()
    ) ;
    info_log "   ... not in the environment" ;
    raise Not_in_env
  with Found x ->
    x


let from_longident ~env ~local_defs ~is_implementation ?pos ctxt ml_or_mli lid =
  File_switching.reset () ;
  Fallback.reset () ;
  Preferences.set ml_or_mli ;
  let ident, is_label = keep_suffix lid in
  let str_ident = String.concat ~sep:"." (Longident.flatten ident) in
  try
    let path', loc =
      if not is_label then lookup ctxt ident env else
      (* If we know it is a record field, we only look for that. *)
      let label_desc = Raw_compat.lookup_label ident env in
      path_and_loc_from_label label_desc env
    in
    if not (is_ghost loc) then
      `Found (None, loc.Location.loc_start)
    else
      let () = debug_log
        "present in the environment, but ghost lock. walking up the typedtree."
      in
      let modules = path_to_list path' in
      let items   = get_top_items ?pos (Browse.of_typer_contents local_defs) in
      match check_item ~source:is_implementation modules items with
      | `Not_found when Fallback.is_set () -> recover ()
      | `Not_found -> `Not_found (str_ident, File_switching.where_am_i ())
      | `ML  loc   -> finalize true loc
      | `MLI loc   -> finalize false loc
  with
  | _ when Fallback.is_set () -> recover ()
  | Not_found
  | File_switching.Can't_move ->
    `Not_found (str_ident, File_switching.where_am_i ())
  | File_not_found path ->
    let msg =
      match path with
      | ML file ->
        sprintf "'%s' seems to originate from '%s' whose ML file could not be \
                 found" str_ident file
      | MLI file ->
        sprintf "'%s' seems to originate from '%s' whose MLI file could not be \
                 found" str_ident file
      | CMT file ->
        sprintf "Needed cmt file of module '%s' to locate '%s' but it is not \
                 present" file str_ident
      | CMTI file ->
        sprintf "Needed cmti file of module '%s' to locate '%s' but it is not \
                 present" file str_ident
    in
    `File_not_found msg
  | Not_in_env -> `Not_in_env str_ident
  | Multiple_matches lst ->
    let matches = String.concat lst ~sep:", " in
    `File_not_found (
      sprintf "Several source files in your path have the same name, and \
               merlin doesn't know which is the right one: %s"
        matches
    )

let from_string ~project ~env ~local_defs ~is_implementation ?pos switch path =
  let inspect_pattern p =
    let open Typedtree in
    match p.pat_desc with
    | Tpat_any -> None
    | Tpat_var _ when String.uncapitalize path = path ->
      (* If the guard is not verified it means the pattern variable we find in
         the typedtree doesn't match the ident we reconstructed from the token
         stream.
         This should only happen in presence of a record pattern, e.g.

             { Location. loc_ghost }

         as is the case at the beginning of this file.
         However it only catches the cases where the ident we locate is prefixed
         by a module name, so not everything is handled.
         Catching everything is harder though, because we need to use the
         location to distinguish between

             { f[o]o = bar }

         and

             { foo = b[a]r }

         (where [ ] represents the cursor.)
         So err... TODO? *)
      None
    | _ -> Some Patt
  in
  let inspect_context pos =
    let browse = Browse.of_typer_contents local_defs in
    match Browse.enclosing pos browse with
    | [] ->
      Logger.infof section (fun fmt pos ->
        Format.pp_print_string fmt "no enclosing around: " ;
        Lexing.print_position fmt pos
      ) pos ;
      None
    | node :: _ ->
      let open BrowseT in
      match node.t_node with
      | Pattern p -> 
        Logger.debugf section (fun fmt p ->
          Format.pp_print_string fmt "current node is: " ;
          Printtyped.pattern 0 fmt p
        ) p ;
        inspect_pattern p
      | Value_description _
      | Type_declaration _
      | Extension_constructor _
      | Module_binding_name _
      | Module_declaration_name _ ->
        debug_log "current node is : %s" @@ BrowseT.string_of_node node.t_node ;
        None
      | Core_type _ -> Some Type
      | Expression _ -> Some Expr
      | _ ->
        Some Unknown
  in
  let lid = Longident.parse path in
  let context =
    match pos with
    | None ->
      info_log "no position available, unable to determine context" ;
      Some Unknown
    | Some pos -> inspect_context pos
  in
  match context with
  | None ->
    info_log "already at origin, doing nothing" ;
    `At_origin
  | Some ctxt ->
    info_log "looking for the source of '%s' (prioritizing %s files)" path
      (match switch with `ML -> ".ml" | `MLI -> ".mli") ;
    Fluid.let' sources_path (Project.source_path project) (fun () ->
    Fluid.let' cmt_path (Project.cmt_path project) (fun () ->
    from_longident ?pos ~env ~local_defs ~is_implementation ctxt switch lid))
