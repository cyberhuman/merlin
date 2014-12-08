open Std
open Typedtree

module Pat = struct
  let pat_extra = []

  let var ?loc pat_env pat_type str =
    let pat_loc =
      match loc with
      | None -> str.Asttypes.loc
      | Some loc -> loc
    in
    let pat_desc = Tpat_var (Ident.create str.Asttypes.txt, str) in
    { pat_desc; pat_loc; pat_extra; pat_type; pat_env }

  let record ?(loc=Location.none) pat_env pat_type lst closed_flag =
    let pat_desc = Tpat_record (lst, closed_flag) in
    { pat_desc; pat_loc = loc; pat_extra; pat_type; pat_env }

  let tuple ?(loc=Location.none) pat_env pat_type lst =
    let pat_desc = Tpat_tuple lst in
    { pat_desc; pat_loc = loc; pat_extra; pat_type; pat_env }

  let construct ?(loc=Location.none) pat_env pat_type lid cstr_desc args =
    let pat_desc = Tpat_construct (lid, cstr_desc, args, false) in
    { pat_desc; pat_loc = loc; pat_extra; pat_type; pat_env }

  let pat_or ?(loc=Location.none) ?row_desc pat_env pat_type p1 p2 =
    let pat_desc = Tpat_or (p1, p2, row_desc) in
    { pat_desc; pat_loc = loc; pat_extra; pat_type; pat_env }
end
