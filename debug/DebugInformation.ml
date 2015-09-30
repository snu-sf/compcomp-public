(* *********************************************************************)
(*                                                                     *)
(*              The Compcert verified compiler                         *)
(*                                                                     *)
(*          Bernhard Schommer, AbsInt Angewandte Informatik GmbH       *)
(*                                                                     *)
(*  AbsInt Angewandte Informatik GmbH. All rights reserved. This file  *)
(*  is distributed under the terms of the INRIA Non-Commercial         *)
(*  License Agreement.                                                 *)
(*                                                                     *)
(* *********************************************************************)

open AST
open BinNums
open C
open Camlcoq
open Cutil

(* This implements an interface for the collection of debugging 
   information. *)

(* Simple id generator *)
let id = ref 0

let next_id () =
  let nid = !id in
  incr id; nid

let reset_id () =
  id := 0

(* Auximilary functions *)
let list_replace c f l =
  List.map (fun a -> if c a then f a else a) l

(* The name of the current compilation unit *)
let file_name: string ref = ref ""

(** All files used in the debug entries *)
module StringSet = Set.Make(String)
let all_files : StringSet.t ref = ref StringSet.empty
let add_file file =
  all_files := StringSet.add file !all_files

(* Types for the information of type info *)
type composite_field =
    {
     cfd_name:        string;
     cfd_typ:         int;
     cfd_bit_size:    int option;
     cfd_bit_offset:  int option;
     cfd_byte_offset: int option;
     cfd_byte_size:   int option;
     cfd_bitfield:    string option;
   }

type composite_type =
    {
     ct_name:        string;
     ct_sou:         struct_or_union;
     ct_file_loc:    location option;
     ct_members:     composite_field list;
     ct_sizeof:      int option;
     ct_declaration: bool;
   }

type ptr_type = {
    pts: int
  }

type const_type = {
    cst_type: int
  }

type volatile_type = {
    vol_type: int
  }


type array_type = {
    arr_type: int;
    arr_size: int64 option list;
  }

type typedef = {
    typedef_file_loc: location option;
    typedef_name:     string;
    typ:              int option;
  }

type enumerator = {
    enumerator_name:     string;
    enumerator_const:    int64;
  }

type enum_type = {
    enum_name:        string;
    enum_byte_size:   int option;
    enum_file_loc:    location option;
    enum_enumerators: enumerator list; 
  }

type int_type = {
    int_kind: ikind;
  }

type float_type = {
    float_kind: fkind;
  }

type parameter_type = {
    param_type: int;
    param_name: string;
  }

type function_type = {
    fun_return_type: int option;
    fun_prototyped:  bool;
    fun_params:      parameter_type list;
  }

type debug_types =
  | IntegerType of int_type
  | FloatType of float_type
  | PointerType of ptr_type
  | ArrayType of array_type
  | CompositeType of composite_type
  | EnumType of enum_type
  | FunctionType of function_type
  | Typedef of typedef
  | ConstType of const_type
  | VolatileType of volatile_type
  | Void

(* All types encountered *)
let types: (int,debug_types) Hashtbl.t = Hashtbl.create 7

(* Lookup table for types *)
let lookup_types: (string, int) Hashtbl.t = Hashtbl.create 7

(* Translate a C.typ to a string needed for hashing *)
let typ_to_string (ty: typ) =
  let buf = Buffer.create 7 in
  let chan = Format.formatter_of_buffer buf in
  Cprint.print_debug_idents := true;
  Cprint.typ chan ty;
  Cprint.print_debug_idents := false;
  Format.pp_print_flush chan ();
  Buffer.contents buf

(* Helper functions for the attributes *)
let strip_attributes typ =
  let strip =  List.filter (fun a -> a = AConst || a = AVolatile) in 
  match typ with
  | TVoid at -> TVoid (strip at)
  | TInt (k,at) ->  TInt (k,strip at)
  | TFloat (k,at) -> TFloat(k,strip at)
  | TPtr (t,at) -> TPtr(t,strip at)
  | TArray (t,s,at) -> TArray(t,s,strip at)
  | TFun (t,arg,v,at) -> TFun(t,arg,v,strip at)
  | TNamed (n,at) -> TNamed(n,strip at)
  | TStruct (n,at) -> TStruct(n,strip at)
  | TUnion (n,at) -> TUnion(n,strip at)
  | TEnum (n,at) -> TEnum(n,strip at)

let strip_last_attribute typ  = 
  let rec hd_opt l = match l with
    [] -> None,[]
  | AConst::rest -> Some AConst,rest
  | AVolatile::rest -> Some AVolatile,rest 
  | _::rest -> hd_opt rest in
  match typ with
  | TVoid at -> let l,r = hd_opt at in
    l,TVoid r
  | TInt (k,at) -> let l,r = hd_opt at in
    l,TInt (k,r)
  | TFloat (k,at) -> let l,r = hd_opt at in
    l,TFloat (k,r)
  | TPtr (t,at) -> let l,r = hd_opt at in
    l,TPtr(t,r)
  | TArray (t,s,at) -> let l,r = hd_opt at in
    l,TArray(t,s,r)
  | TFun (t,arg,v,at) -> let l,r = hd_opt at in
    l,TFun(t,arg,v,r)
  | TNamed (n,at) -> let l,r = hd_opt at in
    l,TNamed(n,r)
  | TStruct (n,at) -> let l,r = hd_opt at in
    l,TStruct(n,r)
  | TUnion (n,at) -> let l,r = hd_opt at in
    l,TUnion(n,r)
  | TEnum (n,at) -> let l,r = hd_opt at in
    l,TEnum(n,r)

(* Does the type already exist? *)
let exist_type (ty: typ) =
  (* We are only interrested in Const and Volatile *)
  let ty = strip_attributes ty in
  Hashtbl.mem lookup_types (typ_to_string ty)

(* Find the type id to an type *)
let find_type (ty: typ) =
  (* We are only interrested in Const and Volatile *)
  let ty = strip_attributes ty in
  Hashtbl.find lookup_types (typ_to_string ty)

(* Add type and information *)
let insert_type (ty: typ) =
  let insert d_ty ty =
    let id = next_id () 
    and name = typ_to_string ty in
    Hashtbl.add types id d_ty;
    Hashtbl.add lookup_types name id;
    id in
  (* We are only interrested in Const and Volatile *)
  let ty = strip_attributes ty in
  let rec typ_aux ty = 
    try find_type ty with
    | Not_found ->
        let d_ty =
          match ty with
          | TVoid _ -> Void
          | TInt (k,_) -> 
              IntegerType ({int_kind = k })
          | TFloat (k,_) ->
              FloatType ({float_kind = k})
          | TPtr (t,_) ->
              let id = attr_aux t in
              PointerType ({pts = id})
          | TArray (t,s,_) ->
              let rec size acc t = (match t with
              | TArray (child,s,_) ->
                  size (s::acc) child
              | _ -> t,List.rev acc) in
              let t,s = size [s] t in
              let id = attr_aux t in
              let arr = {
                arr_type = id;
                arr_size= s;
              } in
              ArrayType arr
          | TFun (t,param,va,_) ->
              let param,prot = (match param with 
              | None -> [],false
              | Some p -> List.map (fun (i,t) -> let t = attr_aux t in 
                {
                 param_type = t;
                 param_name = i.name;               
               }) p,true) in
              let ret = (match t with 
              | TVoid _ -> None
              | _ -> Some (attr_aux t)) in
              let ftype = {
                fun_return_type = ret;
                fun_prototyped = prot;
                fun_params = param;
              } in
              FunctionType ftype
          | TNamed (id,_) ->
              let typ = try
                let _,t =
                  List.find (fun a -> fst a = id.name) CBuiltins.builtins.Builtins.typedefs in
                Some (attr_aux t)
              with Not_found -> None in
              let t = {
                typedef_file_loc = None;
                typedef_name = id.name;
                typ = typ;
              } in
              Typedef t
          | TStruct (id,_) ->
              let str =
                {
                 ct_name = id.name;
                 ct_sou = Struct;
                 ct_file_loc = None;
                 ct_members = [];
                 ct_declaration = false;
                 ct_sizeof = None;
               } in
              CompositeType str
          | TUnion (id,_) ->
              let union =
                {
                 ct_name = id.name;
                 ct_sou = Union;
                 ct_file_loc = None;
                 ct_members = [];
                 ct_declaration = false;
                 ct_sizeof = None;
               } in
              CompositeType union
          | TEnum (id,_) ->
              let enum = 
                {
                 enum_name = id.name;
                 enum_byte_size = None;
                 enum_file_loc = None;
                 enum_enumerators = [];
               } in
              EnumType enum in
        insert d_ty ty
  and attr_aux ty = 
    try
      find_type ty
    with
      Not_found ->
        match strip_last_attribute ty with
        | Some AConst,t -> 
            let id = attr_aux t in
            let const = { cst_type = id} in
            insert (ConstType const) ty
        | Some AVolatile,t ->
            let id = attr_aux t in
            let volatile = {vol_type = id} in
            insert (VolatileType volatile) ty
        | Some (ARestrict|AAlignas _| Attr(_,_)),t ->
            attr_aux t
        | None,t -> typ_aux t
  in
  attr_aux ty

(* Replace the composite information *)
let replace_composite id f =
  let str = Hashtbl.find types id in
  match str with
  | CompositeType comp -> let comp' = f comp in
    if comp <> comp' then Hashtbl.replace types id (CompositeType comp')
  | _ -> assert false (* This should never happen *)

(* Replace the enum information *)
let replace_enum id f =
  let str = Hashtbl.find types id in
  match str with
  | EnumType comp -> let comp' = f comp in
    if comp <> comp' then Hashtbl.replace types id (EnumType comp')
  | _ -> assert false (* This should never happen *)

(* Replace the typdef information *)
let replace_typedef id f =
  let typdef = Hashtbl.find types id in
  match typdef with
  | Typedef typ -> let typ' = f typ in
    if typ <> typ' then Hashtbl.replace types id (Typedef typ')
  | _ -> assert false (* This should never happen *)

(* Types for global definitions *)

(* Information for a global variable *)
type global_variable_information = {
    gvar_name:        string;
    gvar_atom:        atom option;
    gvar_file_loc:    location;
    gvar_declaration: bool;
    gvar_external:    bool;
    gvar_type:        int;
  }

type parameter_information = 
 {
  parameter_name:     string;
  parameter_ident:    int;
  parameter_atom:     atom option;
  parameter_type:     int;
}

type function_information = {
    fun_name:        string;
    fun_atom:        atom option;
    fun_file_loc:    location;
    fun_external:    bool;
    fun_return_type: int option; (* Again the special case of void functions *)
    fun_vararg:      bool;
    fun_parameter:   parameter_information list;
    fun_low_pc:      int option;
    fun_high_pc:     int option;
    fun_scope:       int option;
  }

type definition_type =
  | GlobalVariable of global_variable_information
  | Function of function_information


(* All global definitions encountered *)
let definitions: (int,definition_type) Hashtbl.t = Hashtbl.create 7

(* Mapping from stamp to debug id *)
let stamp_to_definition: (int,int) Hashtbl.t = Hashtbl.create 7

(* Mapping from name to debug id *)
let name_to_definition: (string,int) Hashtbl.t = Hashtbl.create 7

(* Mapping from atom to debug id *)
let atom_to_definition: (atom, int) Hashtbl.t = Hashtbl.create 7

let find_gvar_stamp id =
  let id = (Hashtbl.find stamp_to_definition id) in
  let var = Hashtbl.find definitions id in
  match var with
  | GlobalVariable var -> id,var
  |  _ -> assert false

let find_fun_stamp id =
  let id = (Hashtbl.find stamp_to_definition id) in
  let f = Hashtbl.find definitions id in
  match f with
  | Function f -> id,f
  |  _ -> assert false

let find_fun_atom id =
  let id = (Hashtbl.find atom_to_definition id) in
  let f = Hashtbl.find definitions id in
  match f with
  | Function f -> id,f
  |  _ -> assert false

let replace_var id var =
  let var = GlobalVariable var in
  Hashtbl.replace definitions id var

let replace_fun id f =
  let f = Function f in
  Hashtbl.replace definitions id f


(* Information for local variables *)
type local_variable_information = {
    lvar_name:    string;
    lvar_atom:    atom option;
    lvar_file_loc:location;
    lvar_type:    int;
    lvar_static:  bool;  (* Static variable are mapped to symbols *)
  }

type scope_information = 
  {
   scope_variables: int list; (* Variable and Scope ids *)
 }

type local_information =
  | LocalVariable of local_variable_information
  | Scope of scope_information

(* All local variables *)
let local_variables: (int, local_information) Hashtbl.t = Hashtbl.create 7

(* Mapping from stampt to the debug id of the local variable *)
let stamp_to_local: (int,int) Hashtbl.t = Hashtbl.create 7

(* Mapping form atom to the debug id of the local variable *)
let atom_to_local: (atom, int) Hashtbl.t = Hashtbl.create 7

(* Map from scope id + function id to debug id *)
let scope_to_local: (int * int,int) Hashtbl.t = Hashtbl.create 7

(* Map from scope id + function atom to debug id *)
let atom_to_scope: (atom * int, int) Hashtbl.t = Hashtbl.create 7

let find_lvar_stamp id =
  let id = (Hashtbl.find stamp_to_local id) in
  let v = Hashtbl.find local_variables id in
  match v with
  | LocalVariable v -> id,v
  | _ -> assert false

let replace_lvar id var =
  let var = LocalVariable var in
  Hashtbl.replace local_variables id var

let find_scope_id fid id =
  let id = Hashtbl.find scope_to_local (fid,id) in
  let v = Hashtbl.find local_variables id in
  match v with
  | Scope v -> id,v
  | _ -> assert false

let replace_scope id var =
  let var = Scope var in
  Hashtbl.replace local_variables id var

let gen_comp_typ sou id at = 
  if sou = Struct then
    TStruct (id,at)
  else
    TUnion (id,at)

let insert_global_declaration env dec=
  add_file (fst dec.gloc);
  let insert d_dec stamp =
    let id = next_id () in
    Hashtbl.add definitions id d_dec;
    Hashtbl.add stamp_to_definition stamp id
  in
  match dec.gdesc with
  | Gdecl (sto,id,ty,init) ->
      if  not (is_function_type env ty) then begin
        if not (Hashtbl.mem stamp_to_definition id.stamp)  then begin
          let at_decl,ext = (match sto with
          | Storage_extern -> init = None,true
          | Storage_static -> false,false
          | _ -> false,true) in
          let ty = insert_type ty in
          let decl = {
            gvar_name = id.name;
            gvar_atom = None;
            gvar_file_loc = dec.gloc;
            gvar_declaration = at_decl;
            gvar_external = ext;
            gvar_type = ty;
          } in
          insert (GlobalVariable decl) id.stamp
        end else if init <> None || sto <> Storage_extern then begin (* It is a definition *)
          let id,var = find_gvar_stamp id.stamp in
          replace_var id ({var with gvar_declaration = false;})
        end
      end else if not (Hashtbl.mem name_to_definition id.name) then begin
        (* Implict declarations need special handling *)
        let id' = next_id () in
        Hashtbl.add stamp_to_definition id.stamp id';
        Hashtbl.add name_to_definition id.name id'
      end       
  | Gfundef f ->
      let ret =  (match f.fd_ret with
      | TVoid _ -> None
      | _ -> Some (insert_type f.fd_ret)) in
      let ext =  (match f.fd_storage with
      | Storage_static -> false
      | _ -> true) in
      let params = List.map (fun (p,ty) ->
        let ty = insert_type ty in
        {
         parameter_name = p.name;
         parameter_ident = p.stamp;
         parameter_atom = None;
         parameter_type = ty;
       }) f.fd_params in
      let fd =
      { 
        fun_name = f.fd_name.name;
        fun_atom = None;
        fun_file_loc = dec.gloc;
        fun_external = ext;
        fun_return_type = ret;
        fun_vararg = f.fd_vararg;
        fun_parameter = params;
        fun_low_pc = None;
        fun_high_pc = None;
        fun_scope = None;
      } in
      begin try
        let id' = Hashtbl.find name_to_definition f.fd_name.name in
        Hashtbl.add stamp_to_definition f.fd_name.stamp id';
        Hashtbl.add definitions id' (Function fd)
      with Not_found ->
        insert (Function fd) f.fd_name.stamp
      end
  | Gcompositedecl (sou,id,at) -> 
      ignore (insert_type (gen_comp_typ sou id at));
      let id = find_type (gen_comp_typ sou id []) in
      replace_composite id (fun comp -> if comp.ct_file_loc = None then
        {comp with ct_file_loc = Some (dec.gloc);}
      else comp)
  | Gcompositedef (sou,id,at,fi) -> 
      ignore (insert_type (gen_comp_typ sou id at));
      let id = find_type (gen_comp_typ sou id []) in
      let fi = List.filter (fun f -> f.fld_name <> "") fi in (* Fields without names need no info *)
      let fields = List.map (fun f ->
        {
         cfd_name = f.fld_name;
         cfd_typ = insert_type f.fld_typ;
         cfd_bit_size = f.fld_bitfield;
         cfd_bit_offset = None;
         cfd_byte_offset = None;
         cfd_byte_size = None;
         cfd_bitfield = None;
       }) fi in
      replace_composite id (fun comp ->
        let loc = if comp.ct_file_loc = None then Some dec.gloc else comp.ct_file_loc in
        {comp with ct_file_loc = loc; ct_members = fields; ct_declaration = true;})
  | Gtypedef (id,t) -> 
      let id = insert_type (TNamed (id,[])) in
      let tid = insert_type t in
      replace_typedef id (fun typ -> {typ with typedef_file_loc = Some dec.gloc; typ = Some tid;});
  | Genumdef (n,at,e) -> 
      ignore(insert_type (TEnum (n,at)));
      let id = find_type (TEnum (n,[])) in
      let enumerator = List.map (fun (i,c,_) ->
        {    
             enumerator_name = i.name;
             enumerator_const = c;
       }) e in
      replace_enum id (fun en ->
        {en with enum_file_loc = Some dec.gloc; enum_enumerators = enumerator;})
  | Gpragma _ -> ()

let set_member_offset str field offset =
  let id = find_type (TStruct (str,[])) in
  replace_composite id (fun comp ->
    let name f = f.cfd_name = field || match f.cfd_bitfield with Some n -> n = field | _ -> false in 
    let members = list_replace name (fun a -> {a with cfd_byte_offset = Some offset;}) comp.ct_members in
    {comp with ct_members = members;})

let set_composite_size comp sou size =
  let id = find_type (gen_comp_typ sou comp []) in
  replace_composite id (fun comp -> {comp with ct_sizeof = size;}) 

let set_bitfield_offset str field offset underlying size =
  let id = find_type (TStruct (str,[])) in
  replace_composite id (fun comp ->
    let name f = f.cfd_name = field in
    let members = list_replace name (fun a -> 
      {a with cfd_bit_offset = Some offset; cfd_bitfield = Some underlying; cfd_byte_size = Some size})
        comp.ct_members in
    {comp with ct_members = members;})

let atom_global_variable id atom = 
  try
    let id,var = find_gvar_stamp id.stamp in
    replace_var id ({var with gvar_atom = Some atom;});
    Hashtbl.add atom_to_definition atom id 
  with Not_found -> ()
    
let atom_function id atom =
  try
    let id',f = find_fun_stamp id.stamp in
    replace_fun id' ({f with fun_atom = Some atom;});
    Hashtbl.add atom_to_definition atom id';
    Hashtbl.iter (fun (fid,sid) tid -> if fid = id.stamp then 
      Hashtbl.add atom_to_scope (atom,sid) tid) scope_to_local
  with Not_found -> ()

let atom_parameter fid id atom =
  try
    let fid',f = find_fun_stamp fid.stamp in
    let name p = p.parameter_ident = id.stamp in
    let params = list_replace name (fun p -> {p with parameter_atom = Some atom;}) f.fun_parameter in
    replace_fun fid' ({f with fun_parameter = params;})
  with Not_found -> ()
    
let add_fun_addr atom (high,low) =
  try
    let id,f = find_fun_atom atom in
    replace_fun id ({f with fun_high_pc = Some high; fun_low_pc = Some low;})
  with Not_found -> ()

let atom_local_variable id atom =
  try
    let id,var = find_lvar_stamp id.stamp in
    replace_lvar id ({var with lvar_atom = Some atom;});
    Hashtbl.add atom_to_local atom id
  with Not_found -> ()

let add_lvar_scope f_id var_id s_id =
  try
    let s_id',scope = find_scope_id f_id s_id in
    let var_id,_ = find_lvar_stamp var_id.stamp in 
    replace_scope s_id' ({scope_variables = var_id::scope.scope_variables;})
  with Not_found -> ()

let insert_local_declaration sto id ty loc =
  let ty = insert_type ty in
  let var = {
    lvar_name = id.name;
    lvar_atom = None;
    lvar_file_loc = loc;
    lvar_type = ty;
    lvar_static = sto = Storage_static;
    } in
  let id' = next_id () in
  Hashtbl.add local_variables id' (LocalVariable var);
  Hashtbl.add stamp_to_local id.stamp id'

let new_scope f_id sc_id =
  let scope = {scope_variables = [];} in
  let id = next_id () in
  Hashtbl.add local_variables id (Scope scope);
  Hashtbl.add scope_to_local (f_id,sc_id) id;
  id

let enter_function_scope fun_id sc_id =
  try
    let id = new_scope fun_id sc_id in
    let fun_id,f = find_fun_stamp fun_id in
    replace_fun fun_id ({f with fun_scope = Some id})
  with Not_found -> ()

let enter_scope f_id p_id id =
  try
    let id' = new_scope f_id id in
    let p_id',scope = find_scope_id f_id p_id in
    replace_scope p_id' ({scope_variables = id'::scope.scope_variables;})
  with Not_found  -> ()


type scope_range =
    {
     start_addr: positive option;
     end_addr: positive option;
   }

type var_range =
    {
     range_start: positive option;
     range_end:   positive option;
     var_loc:     int * int builtin_arg;
   }

type var_location =
  | RangeLoc of var_range list
  | FunctionLoc of  int * int builtin_arg (* Stack allocated variables *)

let var_locations: (atom,var_location) Hashtbl.t = Hashtbl.create 7

let scope_ranges: (int,scope_range list) Hashtbl.t = Hashtbl.create 7

let label_translation: (atom * positive, int) Hashtbl.t = Hashtbl.create 7

let add_label atom p i =
  Hashtbl.add label_translation (atom,p) i

(* Auxiliary data structures and functions *)
module IntSet = Set.Make(struct
  type t = int
  let compare (x:int) (y:int) = compare x y
end)

let open_scopes: IntSet.t ref = ref IntSet.empty
let open_vars: atom list ref = ref []

let open_scope atom s_id lbl =
  try
    let s_id = Hashtbl.find atom_to_scope (atom,s_id) in
    let old_r = try Hashtbl.find scope_ranges s_id with Not_found -> [] in
    let n_scop = { start_addr = Some lbl; end_addr = None;} in
    open_scopes := IntSet.add s_id !open_scopes;
    Hashtbl.replace scope_ranges s_id (n_scop::old_r)
  with Not_found -> ()

let close_scope atom s_id lbl =
  try
    let s_id = Hashtbl.find atom_to_scope (atom,s_id) in
    let old_r = try Hashtbl.find scope_ranges s_id with Not_found -> [] in
    let last_r,rest = 
      begin
        match old_r with
        | a::rest -> a,rest
        | _ -> assert false (* We must have an opening scope *)
      end in
    let new_r = ({last_r with end_addr = Some lbl;})::rest in
    open_scopes := IntSet.remove s_id !open_scopes;
    Hashtbl.replace scope_ranges s_id new_r
  with Not_found -> ()

let start_live_range atom lbl loc =
  let old_r = begin try Hashtbl.find var_locations atom with Not_found -> (RangeLoc []) end in
  match old_r with
  | RangeLoc old_r ->
      let n_r = { range_start = Some lbl; range_end = None; var_loc = loc } in
      open_vars := atom::!open_vars;
      Hashtbl.replace var_locations atom (RangeLoc (n_r::old_r))
  | _ -> () (* Parameter that is passed as variable *)

let end_live_range atom lbl =
  try
    let old_r = Hashtbl.find var_locations atom in
    match old_r with
    | RangeLoc (n_r::old_r) ->
        if n_r.range_end = None then (* We can skip non open locations *)
          let n_r = {n_r with  range_end = Some lbl} in
          Hashtbl.replace var_locations atom (RangeLoc (n_r::old_r))
    | _ -> ()
  with Not_found -> ()

let stack_variable atom (sp,loc) =
  Hashtbl.add var_locations atom (FunctionLoc (sp,loc))

let function_end atom loc =
  IntSet.iter (fun id -> close_scope atom id loc) !open_scopes;
  open_scopes := IntSet.empty;
  List.iter (fun atom -> end_live_range atom loc) !open_vars;
  open_vars:= []

let compilation_section_start: (string,int * int * int * string) Hashtbl.t = Hashtbl.create 7
let compilation_section_end: (string,int) Hashtbl.t = Hashtbl.create 7

let add_compilation_section_start sec addr =
  Hashtbl.add compilation_section_start sec addr

let add_compilation_section_end sec addr =
  Hashtbl.add compilation_section_end sec addr

let exists_section sec =
  Hashtbl.mem compilation_section_start sec

let filenum: (string * string,int) Hashtbl.t = Hashtbl.create 7

let compute_file_enum end_label entry_label line_end =
  Hashtbl.iter (fun sec (_,_,_,secname) ->
    Hashtbl.add compilation_section_end sec (end_label secname);
    StringSet.iter (fun file ->
      let lbl = entry_label file in
      Hashtbl.add filenum (sec,file) lbl) !all_files;
    line_end ()) compilation_section_start

let init name =
  id := 0;
  file_name := name;
  Hashtbl.reset types;
  Hashtbl.reset lookup_types;
  Hashtbl.reset definitions;
  Hashtbl.reset stamp_to_definition;
  Hashtbl.reset name_to_definition;
  Hashtbl.reset atom_to_definition;
  Hashtbl.reset local_variables;
  Hashtbl.reset stamp_to_local;
  Hashtbl.reset atom_to_local;
  Hashtbl.reset scope_to_local;
  Hashtbl.reset compilation_section_start;
  Hashtbl.reset compilation_section_end;
  Hashtbl.reset filenum;
  all_files := StringSet.empty