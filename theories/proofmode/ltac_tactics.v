From iris.proofmode Require Import coq_tactics reduction.
From iris.proofmode Require Import base intro_patterns spec_patterns sel_patterns.
From iris.bi Require Export bi telescopes.
From stdpp Require Import namespaces.
From iris.proofmode Require Export classes notation.
From stdpp Require Import hlist pretty.
Set Default Proof Using "Type".
Export ident.

(** For most of the tactics, we want to have tight control over the order and
way in which type class inference is performed. To that end, many tactics make
use of [notypeclasses refine] and the [iSolveTC] tactic to manually invoke type
class inference.

The tactic [iSolveTC] does not use [apply _], as that often leads to issues
because it will try to solve all evars whose type is a typeclass, in
dependency order (according to Matthieu). If one fails, it aborts. However, we
generally rely on progress on the main goal to be solved to make progress
elsewhere. With [typeclasses eauto], that seems to work better.

A drawback of [typeclasses eauto] is that it is multi-success, i.e. whenever
subsequent tactics fail, it will backtrack to [typeclasses eauto] to try the
next type class instance. This is almost always undesired and leads to poor
performance and horrible error messages, so we wrap it in a [once]. *)
Ltac iSolveTC :=
  solve [once (typeclasses eauto)].

(** Tactic used for solving side-conditions arising from TC resolution in iMod
and iInv. *)
Ltac iSolveSideCondition :=
  split_and?; try solve [ fast_done | solve_ndisj ].

(** Used for printing [string]s and [ident]s. *)
Ltac pretty_ident H :=
  lazymatch H with
  | INamed ?H => H
  | ?H => H
  end.

(** * Misc *)

Ltac iMissingHyps Hs :=
  let Δ :=
    lazymatch goal with
    | |- envs_entails ?Δ _ => Δ
    | |- context[ envs_split _ _ ?Δ ] => Δ
    end in
  let Hhyps := pm_eval (envs_dom Δ) in
  eval vm_compute in (list_difference Hs Hhyps).

Ltac iTypeOf H :=
  let Δ := match goal with |- envs_entails ?Δ _ => Δ end in
  pm_eval (envs_lookup H Δ).

Tactic Notation "iMatchHyp" tactic1(tac) :=
  match goal with
  | |- context[ environments.Esnoc _ ?x ?P ] => tac x P
  end.

(** * Start a proof *)
Tactic Notation "iStartProof" :=
  lazymatch goal with
  | |- envs_entails _ _ => idtac
  | |- ?φ => notypeclasses refine (as_emp_valid_2 φ _ _);
               [iSolveTC || fail "iStartProof: not a BI assertion"
               |apply tac_adequate]
  end.

(* Same as above, with 2 differences :
   - We can specify a BI in which we want the proof to be done
   - If the goal starts with a let or a ∀, they are automatically
     introduced. *)
Tactic Notation "iStartProof" uconstr(PROP) :=
  lazymatch goal with
  | |- @envs_entails ?PROP' _ _ =>
    (* This cannot be shared with the other [iStartProof], because
    type_term has a non-negligeable performance impact. *)
    let x := type_term (eq_refl : @eq Type PROP PROP') in idtac

  (* We eta-expand [as_emp_valid_2], in order to make sure that
     [iStartProof PROP] works even if [PROP] is the carrier type. In
     this case, typing this expression will end up unifying PROP with
     [bi_car _], and hence trigger the canonical structures mechanism
     to find the corresponding bi. *)
  | |- ?φ => notypeclasses refine ((λ P : PROP, @as_emp_valid_2 φ _ P) _ _ _);
               [iSolveTC || fail "iStartProof: not a BI assertion"
               |apply tac_adequate]
  end.

(** * Generate a fresh identifier *)
(* Tactic Notation tactics cannot return terms *)
Ltac iFresh :=
  (* We need to increment the environment counter using [tac_fresh].
     But because [iFresh] returns a value, we have to let bind
     [tac_fresh] wrapped under a match to force evaluation of this
     side-effect. See https://stackoverflow.com/a/46178884 *)
  let do_incr :=
      lazymatch goal with
      | _ => iStartProof; eapply tac_fresh; first by (pm_reflexivity)
      end in
  lazymatch goal with
  |- envs_entails ?Δ _ =>
    let n := pm_eval (env_counter Δ) in
    constr:(IAnon n)
  end.

(** * Simplification *)
Tactic Notation "iEval" tactic(t) :=
  iStartProof;
  eapply tac_eval;
    [let x := fresh in intros x; t; unfold x; reflexivity
    |].

Tactic Notation "iEval" tactic(t) "in" constr(H) :=
  iStartProof;
  eapply tac_eval_in with _ H _ _ _;
    [pm_reflexivity || fail "iEval:" H "not found"
    |let x := fresh in intros x; t; unfold x; reflexivity
    |pm_reflexivity
    |].

Tactic Notation "iSimpl" := iEval simpl.
Tactic Notation "iSimpl" "in" constr(H) := iEval simpl in H.

(* It would be nice to also have an `iSsrRewrite`, however, for this we need to
pass arguments to Ssreflect's `rewrite` like `/= foo /bar` in Ltac, see:

  https://sympa.inria.fr/sympa/arc/coq-club/2018-01/msg00000.html

PMP told me (= Robbert) in person that this is not possible today, but may be
possible in Ltac2. *)

(** * Context manipulation *)
Tactic Notation "iRename" constr(H1) "into" constr(H2) :=
  eapply tac_rename with _ H1 H2 _ _; (* (i:=H1) (j:=H2) *)
    [pm_reflexivity ||
     let H1 := pretty_ident H1 in
     fail "iRename:" H1 "not found"
    |pm_reflexivity ||
     let H2 := pretty_ident H2 in
     fail "iRename:" H2 "not fresh"|].

Local Inductive esel_pat :=
  | ESelPure
  | ESelIdent : bool → ident → esel_pat.

Local Ltac iElaborateSelPat_go pat Δ Hs :=
  lazymatch pat with
  | [] => eval cbv in Hs
  | SelPure :: ?pat =>  iElaborateSelPat_go pat Δ (ESelPure :: Hs)
  | SelPersistent :: ?pat =>
    let Hs' := pm_eval (env_dom (env_intuitionistic Δ)) in
    let Δ' := pm_eval (envs_clear_persistent Δ) in
    iElaborateSelPat_go pat Δ' ((ESelIdent true <$> Hs') ++ Hs)
  | SelSpatial :: ?pat =>
    let Hs' := pm_eval (env_dom (env_spatial Δ)) in
    let Δ' := pm_eval (envs_clear_spatial Δ) in
    iElaborateSelPat_go pat Δ' ((ESelIdent false <$> Hs') ++ Hs)
  | SelIdent ?H :: ?pat =>
    lazymatch pm_eval (envs_lookup_delete false H Δ) with
    | Some (?p,_,?Δ') =>  iElaborateSelPat_go pat Δ' (ESelIdent p H :: Hs)
    | None =>
      let H := pretty_ident H in
      fail "iElaborateSelPat:" H "not found"
    end
  end.
Ltac iElaborateSelPat pat :=
  lazymatch goal with
  | |- envs_entails ?Δ _ =>
    let pat := sel_pat.parse pat in iElaborateSelPat_go pat Δ (@nil esel_pat)
  end.

Local Ltac iClearHyp H :=
  eapply tac_clear with _ H _ _; (* (i:=H) *)
    [pm_reflexivity ||
     let H := pretty_ident H in
     fail "iClear:" H "not found"
    |pm_reduce; iSolveTC ||
     let H := pretty_ident H in
     let P := match goal with |- TCOr (Affine ?P) _ => P end in
     fail "iClear:" H ":" P "not affine and the goal not absorbing"
    |].

Local Ltac iClear_go Hs :=
  lazymatch Hs with
  | [] => idtac
  | ESelPure :: ?Hs => clear; iClear_go Hs
  | ESelIdent _ ?H :: ?Hs => iClearHyp H; iClear_go Hs
  end.
Tactic Notation "iClear" constr(Hs) :=
  iStartProof; let Hs := iElaborateSelPat Hs in iClear_go Hs.

Tactic Notation "iClear" "(" ident_list(xs) ")" constr(Hs) :=
  iClear Hs; clear xs.

(** * Assumptions *)
Tactic Notation "iExact" constr(H) :=
  eapply tac_assumption with _ H _ _; (* (i:=H) *)
    [pm_reflexivity ||
     let H := pretty_ident H in
     fail "iExact:" H "not found"
    |iSolveTC ||
     let H := pretty_ident H in
     let P := match goal with |- FromAssumption _ ?P _ => P end in
     fail "iExact:" H ":" P "does not match goal"
    |pm_reduce; iSolveTC ||
     let H := pretty_ident H in
     fail "iExact:" H "not absorbing and the remaining hypotheses not affine"].

Tactic Notation "iAssumptionCore" :=
  let rec find Γ i P :=
    lazymatch Γ with
    | Esnoc ?Γ ?j ?Q => first [unify P Q; unify i j|find Γ i P]
    end in
  match goal with
  | |- envs_lookup ?i (Envs ?Γp ?Γs _) = Some (_, ?P) =>
     first [is_evar i; fail 1 | pm_reflexivity]
  | |- envs_lookup ?i (Envs ?Γp ?Γs _) = Some (_, ?P) =>
     is_evar i; first [find Γp i P | find Γs i P]; pm_reflexivity
  | |- envs_lookup_delete _ ?i (Envs ?Γp ?Γs _) = Some (_, ?P, _) =>
     first [is_evar i; fail 1 | pm_reflexivity]
  | |- envs_lookup_delete _ ?i (Envs ?Γp ?Γs _) = Some (_, ?P, _) =>
     is_evar i; first [find Γp i P | find Γs i P]; pm_reflexivity
  end.

Tactic Notation "iAssumption" :=
  let Hass := fresh in
  let rec find p Γ Q :=
    lazymatch Γ with
    | Esnoc ?Γ ?j ?P => first
       [pose proof (_ : FromAssumption p P Q) as Hass;
        eapply (tac_assumption _ _ j p P);
          [pm_reflexivity
          |apply Hass
          |pm_reduce; iSolveTC ||
           fail 1 "iAssumption:" j "not absorbing and the remaining hypotheses not affine"]
       |assert (P = False%I) as Hass by reflexivity;
        apply (tac_false_destruct _ j p P);
          [pm_reflexivity
          |exact Hass]
       |find p Γ Q]
    end in
  lazymatch goal with
  | |- envs_entails (Envs ?Γp ?Γs _) ?Q =>
     first [find true Γp Q | find false Γs Q
           |fail "iAssumption:" Q "not found"]
  end.

(** * False *)
Tactic Notation "iExFalso" := apply tac_ex_falso.

(** * Making hypotheses persistent or pure *)
Local Tactic Notation "iPersistent" constr(H) :=
  eapply tac_persistent with _ H _ _ _; (* (i:=H) *)
    [pm_reflexivity ||
     let H := pretty_ident H in
     fail "iPersistent:" H "not found"
    |iSolveTC ||
     let P := match goal with |- IntoPersistent _ ?P _ => P end in
     fail "iPersistent:" P "not persistent"
    |pm_reduce; iSolveTC ||
     let P := match goal with |- TCOr (Affine ?P) _ => P end in
     fail "iPersistent:" P "not affine and the goal not absorbing"
    |pm_reflexivity|].

Local Tactic Notation "iPure" constr(H) "as" simple_intropattern(pat) :=
  eapply tac_pure with _ H _ _ _; (* (i:=H1) *)
    [pm_reflexivity ||
     let H := pretty_ident H in
     fail "iPure:" H "not found"
    |iSolveTC ||
     let P := match goal with |- IntoPure ?P _ => P end in
     fail "iPure:" P "not pure"
    |pm_reduce; iSolveTC ||
     let P := match goal with |- TCOr (Affine ?P) _ => P end in
     fail "iPure:" P "not affine and the goal not absorbing"
    |intros pat].

Tactic Notation "iEmpIntro" :=
  iStartProof;
  eapply tac_emp_intro;
    [pm_reduce; iSolveTC ||
     fail "iEmpIntro: spatial context contains non-affine hypotheses"].

Tactic Notation "iPureIntro" :=
  iStartProof;
  eapply tac_pure_intro;
    [pm_reflexivity
    |iSolveTC ||
     let P := match goal with |- FromPure _ ?P _ => P end in
     fail "iPureIntro:" P "not pure"
    |].

(** Framing *)
Local Ltac iFrameFinish :=
  pm_prettify;
  try match goal with
  | |- envs_entails _ True => by iPureIntro
  | |- envs_entails _ emp => iEmpIntro
  end.

Local Ltac iFramePure t :=
  iStartProof;
  let φ := type of t in
  eapply (tac_frame_pure _ _ _ _ t);
    [iSolveTC || fail "iFrame: cannot frame" φ
    |iFrameFinish].

Local Ltac iFrameHyp H :=
  iStartProof;
  eapply tac_frame with _ H _ _ _;
    [pm_reflexivity ||
     let H := pretty_ident H in
     fail "iFrame:" H "not found"
    |iSolveTC ||
     let R := match goal with |- Frame _ ?R _ _ => R end in
     fail "iFrame: cannot frame" R
    |iFrameFinish].

Local Ltac iFrameAnyPure :=
  repeat match goal with H : _ |- _ => iFramePure H end.

Local Ltac iFrameAnyPersistent :=
  iStartProof;
  let rec go Hs :=
    match Hs with [] => idtac | ?H :: ?Hs => repeat iFrameHyp H; go Hs end in
  match goal with
  | |- envs_entails ?Δ _ =>
     let Hs := eval cbv in (env_dom (env_intuitionistic Δ)) in go Hs
  end.

Local Ltac iFrameAnySpatial :=
  iStartProof;
  let rec go Hs :=
    match Hs with [] => idtac | ?H :: ?Hs => try iFrameHyp H; go Hs end in
  match goal with
  | |- envs_entails ?Δ _ =>
     let Hs := eval cbv in (env_dom (env_spatial Δ)) in go Hs
  end.

Tactic Notation "iFrame" := iFrameAnySpatial.

Tactic Notation "iFrame" "(" constr(t1) ")" :=
  iFramePure t1.
Tactic Notation "iFrame" "(" constr(t1) constr(t2) ")" :=
  iFramePure t1; iFrame ( t2 ).
Tactic Notation "iFrame" "(" constr(t1) constr(t2) constr(t3) ")" :=
  iFramePure t1; iFrame ( t2 t3 ).
Tactic Notation "iFrame" "(" constr(t1) constr(t2) constr(t3) constr(t4) ")" :=
  iFramePure t1; iFrame ( t2 t3 t4 ).
Tactic Notation "iFrame" "(" constr(t1) constr(t2) constr(t3) constr(t4)
    constr(t5) ")" :=
  iFramePure t1; iFrame ( t2 t3 t4 t5 ).
Tactic Notation "iFrame" "(" constr(t1) constr(t2) constr(t3) constr(t4)
    constr(t5) constr(t6) ")" :=
  iFramePure t1; iFrame ( t2 t3 t4 t5 t6 ).
Tactic Notation "iFrame" "(" constr(t1) constr(t2) constr(t3) constr(t4)
    constr(t5) constr(t6) constr(t7) ")" :=
  iFramePure t1; iFrame ( t2 t3 t4 t5 t6 t7 ).
Tactic Notation "iFrame" "(" constr(t1) constr(t2) constr(t3) constr(t4)
    constr(t5) constr(t6) constr(t7) constr(t8)")" :=
  iFramePure t1; iFrame ( t2 t3 t4 t5 t6 t7 t8 ).

Local Ltac iFrame_go Hs :=
  lazymatch Hs with
  | [] => idtac
  | SelPure :: ?Hs => iFrameAnyPure; iFrame_go Hs
  | SelPersistent :: ?Hs => iFrameAnyPersistent; iFrame_go Hs
  | SelSpatial :: ?Hs => iFrameAnySpatial; iFrame_go Hs
  | SelIdent ?H :: ?Hs => iFrameHyp H; iFrame_go Hs
  end.

Tactic Notation "iFrame" constr(Hs) :=
  let Hs := sel_pat.parse Hs in iFrame_go Hs.
Tactic Notation "iFrame" "(" constr(t1) ")" constr(Hs) :=
  iFramePure t1; iFrame Hs.
Tactic Notation "iFrame" "(" constr(t1) constr(t2) ")" constr(Hs) :=
  iFramePure t1; iFrame ( t2 ) Hs.
Tactic Notation "iFrame" "(" constr(t1) constr(t2) constr(t3) ")" constr(Hs) :=
  iFramePure t1; iFrame ( t2 t3 ) Hs.
Tactic Notation "iFrame" "(" constr(t1) constr(t2) constr(t3) constr(t4) ")"
    constr(Hs) :=
  iFramePure t1; iFrame ( t2 t3 t4 ) Hs.
Tactic Notation "iFrame" "(" constr(t1) constr(t2) constr(t3) constr(t4)
    constr(t5) ")" constr(Hs) :=
  iFramePure t1; iFrame ( t2 t3 t4 t5 ) Hs.
Tactic Notation "iFrame" "(" constr(t1) constr(t2) constr(t3) constr(t4)
    constr(t5) constr(t6) ")" constr(Hs) :=
  iFramePure t1; iFrame ( t2 t3 t4 t5 t6 ) Hs.
Tactic Notation "iFrame" "(" constr(t1) constr(t2) constr(t3) constr(t4)
    constr(t5) constr(t6) constr(t7) ")" constr(Hs) :=
  iFramePure t1; iFrame ( t2 t3 t4 t5 t6 t7 ) Hs.
Tactic Notation "iFrame" "(" constr(t1) constr(t2) constr(t3) constr(t4)
    constr(t5) constr(t6) constr(t7) constr(t8)")" constr(Hs) :=
  iFramePure t1; iFrame ( t2 t3 t4 t5 t6 t7 t8 ) Hs.

(** * Basic introduction tactics *)
Local Tactic Notation "iIntro" "(" simple_intropattern(x) ")" :=
  (* In the case the goal starts with an [let x := _ in _], we do not
     want to unfold x and start the proof mode. Instead, we want to
     use intros. So [iStartProof] has to be called only if [intros]
     fails *)
  intros x ||
    (iStartProof;
     lazymatch goal with
     | |- envs_entails _ _ =>
       eapply tac_forall_intro;
       [iSolveTC ||
              let P := match goal with |- FromForall ?P _ => P end in
              fail "iIntro: cannot turn" P "into a universal quantifier"
       |pm_prettify; intros x]
     end).

Local Tactic Notation "iIntro" constr(H) :=
  iStartProof;
  first
  [ (* (?Q → _) *)
    eapply tac_impl_intro with _ H _ _ _; (* (i:=H) *)
      [iSolveTC
      |pm_reduce; iSolveTC ||
       let P := lazymatch goal with |- Persistent ?P => P end in
       fail 1 "iIntro: introducing non-persistent" H ":" P
              "into non-empty spatial context"
      |pm_reflexivity ||
       let H := pretty_ident H in
       fail 1 "iIntro:" H "not fresh"
      |iSolveTC
      |]
  | (* (_ -∗ _) *)
    eapply tac_wand_intro with _ H _ _; (* (i:=H) *)
      [iSolveTC
      | pm_reflexivity ||
        let H := pretty_ident H in
        fail 1 "iIntro:" H "not fresh"
      |]
  | fail "iIntro: nothing to introduce" ].

Local Tactic Notation "iIntro" "#" constr(H) :=
  iStartProof;
  first
  [ (* (?P → _) *)
    eapply tac_impl_intro_persistent with _ H _ _ _; (* (i:=H) *)
      [iSolveTC
      |iSolveTC ||
       let P := match goal with |- IntoPersistent _ ?P _ => P end in
       fail 1 "iIntro:" P "not persistent"
      |pm_reflexivity ||
       let H := pretty_ident H in
       fail 1 "iIntro:" H "not fresh"
      |]
  | (* (?P -∗ _) *)
    eapply tac_wand_intro_persistent with _ H _ _ _; (* (i:=H) *)
      [ iSolveTC
      | iSolveTC ||
       let P := match goal with |- IntoPersistent _ ?P _ => P end in
       fail 1 "iIntro:" P "not persistent"
      |iSolveTC ||
       let P := match goal with |- TCOr (Affine ?P) _ => P end in
       fail 1 "iIntro:" P "not affine and the goal not absorbing"
      |pm_reflexivity ||
       let H := pretty_ident H in
       fail 1 "iIntro:" H "not fresh"
      |]
  | fail "iIntro: nothing to introduce" ].

Local Tactic Notation "iIntro" "_" :=
  first
  [ (* (?Q → _) *)
    iStartProof; eapply tac_impl_intro_drop;
    [ iSolveTC | ]
  | (* (_ -∗ _) *)
    iStartProof; eapply tac_wand_intro_drop;
      [ iSolveTC
      | iSolveTC ||
       let P := match goal with |- TCOr (Affine ?P) _ => P end in
       fail 1 "iIntro:" P "not affine and the goal not absorbing"
      |]
  | (* (∀ _, _) *) iIntro (_)
  | fail 1 "iIntro: nothing to introduce" ].

Local Tactic Notation "iIntroForall" :=
  lazymatch goal with
  | |- ∀ _, ?P => fail (* actually an →, this is handled by iIntro below *)
  | |- ∀ _, _ => intro
  | |- let _ := _ in _ => intro
  | |- _ =>
    iStartProof;
    lazymatch goal with
    | |- envs_entails _ (∀ x : _, _) => let x' := fresh x in iIntro (x')
    end
  end.
Local Tactic Notation "iIntro" :=
  lazymatch goal with
  | |- _ → ?P => intro
  | |- _ =>
    iStartProof;
    lazymatch goal with
    | |- envs_entails _ (_ -∗ _) => iIntro (?) || let H := iFresh in iIntro #H || iIntro H
    | |- envs_entails _ (_ → _) => iIntro (?) || let H := iFresh in iIntro #H || iIntro H
    end
  end.

(** * Specialize *)
Record iTrm {X As S} :=
  ITrm { itrm : X ; itrm_vars : hlist As ; itrm_hyps : S }.
Arguments ITrm {_ _ _} _ _ _.

Notation "( H $! x1 .. xn )" :=
  (ITrm H (hcons x1 .. (hcons xn hnil) ..) "") (at level 0, x1, xn at level 9).
Notation "( H $! x1 .. xn 'with' pat )" :=
  (ITrm H (hcons x1 .. (hcons xn hnil) ..) pat) (at level 0, x1, xn at level 9).
Notation "( H 'with' pat )" := (ITrm H hnil pat) (at level 0).

(** There is some hacky stuff going on here: because of Coq bug #6583, unresolved
type classes in the arguments `xs` are resolved at arbitrary moments. Tactics
like `apply`, `split` and `eexists` wrongly trigger type class search to resolve
these holes. To avoid TC being triggered too eagerly, this tactic uses `refine`
at most places instead of `apply`. *)
Local Ltac iSpecializeArgs_go H xs :=
    lazymatch xs with
    | hnil => idtac
    | hcons ?x ?xs =>
       notypeclasses refine (tac_forall_specialize _ _ H _ _ _ _ _ _ _);
         [pm_reflexivity ||
          let H := pretty_ident H in
          fail "iSpecialize:" H "not found"
         |iSolveTC ||
          let P := match goal with |- IntoForall ?P _ => P end in
          fail "iSpecialize: cannot instantiate" P "with" x
         |lazymatch goal with (* Force [A] in [ex_intro] to deal with coercions. *)
          | |- ∃ _ : ?A, _ =>
            notypeclasses refine (@ex_intro A _ x (conj _ _))
          end; [shelve..|pm_reflexivity|iSpecializeArgs_go H xs]]
    end.
Local Tactic Notation "iSpecializeArgs" constr(H) open_constr(xs) :=
  iSpecializeArgs_go H xs.

Ltac iSpecializePat_go H1 pats :=
  let solve_to_wand H1 :=
    iSolveTC ||
    let P := match goal with |- IntoWand _ _ ?P _ _ => P end in
    fail "iSpecialize:" P "not an implication/wand" in
  let solve_done d :=
    lazymatch d with
    | true =>
       done ||
       let Q := match goal with |- envs_entails _ ?Q => Q end in
       fail "iSpecialize: cannot solve" Q "using done"
    | false => idtac
    end in
  lazymatch pats with
    | [] => idtac
    | SForall :: ?pats =>
       idtac "[IPM] The * specialization pattern is deprecated because it is applied implicitly.";
       iSpecializePat_go H1 pats
    | SIdent ?H2 :: ?pats =>
       notypeclasses refine (tac_specialize _ _ _ H2 _ H1 _ _ _ _ _ _ _ _ _ _);
         [pm_reflexivity ||
          let H2 := pretty_ident H2 in
          fail "iSpecialize:" H2 "not found"
         |pm_reflexivity ||
          let H1 := pretty_ident H1 in
          fail "iSpecialize:" H1 "not found"
         |iSolveTC ||
          let P := match goal with |- IntoWand _ _ ?P ?Q _ => P end in
          let Q := match goal with |- IntoWand _ _ ?P ?Q _ => Q end in
          fail "iSpecialize: cannot instantiate" P "with" Q
         |pm_reflexivity|iSpecializePat_go H1 pats]
    | SPureGoal ?d :: ?pats =>
       notypeclasses refine (tac_specialize_assert_pure _ _ H1 _ _ _ _ _ _ _ _ _ _ _ _);
         [pm_reflexivity ||
          let H1 := pretty_ident H1 in
          fail "iSpecialize:" H1 "not found"
         |solve_to_wand H1
         |iSolveTC ||
          let Q := match goal with |- FromPure _ ?Q _ => Q end in
          fail "iSpecialize:" Q "not pure"
         |pm_reflexivity
         |solve_done d (*goal*)
         |iSpecializePat_go H1 pats]
    | SGoal (SpecGoal GPersistent false ?Hs_frame [] ?d) :: ?pats =>
       notypeclasses refine (tac_specialize_assert_persistent _ _ _ H1 _ _ _ _ _ _ _ _ _ _ _ _ _);
         [pm_reflexivity ||
          let H1 := pretty_ident H1 in
          fail "iSpecialize:" H1 "not found"
         |solve_to_wand H1
         |iSolveTC ||
          let Q := match goal with |- Persistent ?Q => Q end in
          fail "iSpecialize:" Q "not persistent"
         |iSolveTC
         |pm_reflexivity
         |iFrame Hs_frame; solve_done d (*goal*)
         |iSpecializePat_go H1 pats]
    | SGoal (SpecGoal GPersistent _ _ _ _) :: ?pats =>
       fail "iSpecialize: cannot select hypotheses for persistent premise"
    | SGoal (SpecGoal ?m ?lr ?Hs_frame ?Hs ?d) :: ?pats =>
       let Hs' := eval cbv in (if lr then Hs else Hs_frame ++ Hs) in
       notypeclasses refine (tac_specialize_assert _ _ _ _ H1 _ lr Hs' _ _ _ _ _ _ _ _ _ _ _);
         [pm_reflexivity ||
          let H1 := pretty_ident H1 in
          fail "iSpecialize:" H1 "not found"
         |solve_to_wand H1
         |lazymatch m with
          | GSpatial => notypeclasses refine (add_modal_id _ _)
          | GModal => iSolveTC || fail "iSpecialize: goal not a modality"
          end
         |pm_reflexivity ||
          let Hs' := iMissingHyps Hs' in
          fail "iSpecialize: hypotheses" Hs' "not found"
         |iFrame Hs_frame; solve_done d (*goal*)
         |iSpecializePat_go H1 pats]
    | SAutoFrame GPersistent :: ?pats =>
       notypeclasses refine (tac_specialize_assert_persistent _ _ _ H1 _ _ _ _ _ _ _ _ _ _ _ _ _);
         [pm_reflexivity ||
          let H1 := pretty_ident H1 in
          fail "iSpecialize:" H1 "not found"
         |solve_to_wand H1
         |iSolveTC ||
          let Q := match goal with |- Persistent ?Q => Q end in
          fail "iSpecialize:" Q "not persistent"
         |pm_reflexivity
         |solve [iFrame "∗ #"]
         |iSpecializePat_go H1 pats]
    | SAutoFrame ?m :: ?pats =>
       notypeclasses refine (tac_specialize_frame _ _ H1 _ _ _ _ _ _ _ _ _ _ _ _);
         [pm_reflexivity ||
          let H1 := pretty_ident H1 in
          fail "iSpecialize:" H1 "not found"
         |solve_to_wand H1
         |lazymatch m with
          | GSpatial => notypeclasses refine (add_modal_id _ _)
          | GModal => iSolveTC || fail "iSpecialize: goal not a modality"
          end
         |first
            [notypeclasses refine (tac_unlock_emp _ _ _)
            |notypeclasses refine (tac_unlock_True _ _ _)
            |iFrame "∗ #"; notypeclasses refine (tac_unlock _ _ _)
            |fail "iSpecialize: premise cannot be solved by framing"]
         |exact eq_refl]; iIntro H1; iSpecializePat_go H1 pats
    end.

Local Tactic Notation "iSpecializePat" open_constr(H) constr(pat) :=
  let pats := spec_pat.parse pat in iSpecializePat_go H pats.

(* The argument [p] denotes whether the conclusion of the specialized term is
persistent. If so, one can use all spatial hypotheses for both proving the
premises and the remaning goal. The argument [p] can either be a Boolean or an
introduction pattern, which will be coerced into [true] when it solely contains
`#` or `%` patterns at the top-level.

In case the specialization pattern in [t] states that the modality of the goal
should be kept for one of the premises (i.e. [>[H1 .. Hn]] is used) then [p]
defaults to [false] (i.e. spatial hypotheses are not preserved). *)
Tactic Notation "iSpecializeCore" open_constr(H)
    "with" open_constr(xs) open_constr(pat) "as" constr(p) :=
  let p := intro_pat_persistent p in
  let pat := spec_pat.parse pat in
  let H :=
    lazymatch type of H with
    | string => constr:(INamed H)
    | _ => H
    end in
  iSpecializeArgs H xs; [..|
  lazymatch type of H with
  | ident =>
    (* The lemma [tac_specialize_persistent_helper] allows one to use all
    spatial hypotheses for both proving the premises of the lemma we
    specialize as well as those of the remaining goal. We can only use it when
    the result of the specialization is persistent, and no modality is
    eliminated. We do not use [tac_specialize_persistent_helper] in the case
    only universal quantifiers and no implications or wands are instantiated
    (i.e [pat = []]) because it is a.) not needed, and b.) more efficient. *)
    let pat := spec_pat.parse pat in
    lazymatch eval compute in
      (p && bool_decide (pat ≠ []) && negb (existsb spec_pat_modal pat)) with
    | true =>
       (* FIXME: do something reasonable when the BI is not affine *)
       notypeclasses refine (tac_specialize_persistent_helper _ _ H _ _ _ _ _ _ _ _ _ _ _);
         [pm_reflexivity ||
          let H := pretty_ident H in
          fail "iSpecialize:" H "not found"
         |iSpecializePat H pat;
           [..
           |notypeclasses refine (tac_specialize_persistent_helper_done _ H _ _ _);
            pm_reflexivity]
         |iSolveTC ||
          let Q := match goal with |- IntoPersistent _ ?Q _ => Q end in
          fail "iSpecialize:" Q "not persistent"
         |pm_reduce; iSolveTC ||
          let Q := match goal with |- TCAnd _ (Affine ?Q) => Q end in
          fail "iSpecialize:" Q "not affine"
         |pm_reflexivity
         |(* goal *)]
    | false => iSpecializePat H pat
    end
  | _ => fail "iSpecialize:" H "should be a hypothesis, use iPoseProof instead"
  end].

Tactic Notation "iSpecializeCore" open_constr(t) "as" constr(p) :=
  lazymatch type of t with
  | string => iSpecializeCore t with hnil "" as p
  | ident => iSpecializeCore t with hnil "" as p
  | _ =>
    lazymatch t with
    | ITrm ?H ?xs ?pat => iSpecializeCore H with xs pat as p
    | _ => fail "iSpecialize:" t "should be a proof mode term"
    end
  end.

Tactic Notation "iSpecialize" open_constr(t) :=
  iSpecializeCore t as false.
Tactic Notation "iSpecialize" open_constr(t) "as" "#" :=
  iSpecializeCore t as true.

(** * Pose proof *)
(* The tactic [iIntoEmpValid] tactic solves a goal [bi_emp_valid Q]. The
argument [t] must be a Coq term whose type is of the following shape:

[∀ (x_1 : A_1) .. (x_n : A_n), φ]

and so that we have an instance `AsValid φ Q`.

Examples of such [φ]s are

- [bi_emp_valid P], in which case [Q] should be [P]
- [P1 ⊢ P2], in which case [Q] should be [P1 -∗ P2]
- [P1 ⊣⊢ P2], in which case [Q] should be [P1 ↔ P2]

The tactic instantiates each dependent argument [x_i] with an evar and generates
a goal [R] for each non-dependent argument [x_i : R].  For example, if the
original goal was [Q] and [t] has type [∀ x, P x → Q], then it generates an evar
[?x] for [x] and a subgoal [P ?x]. *)
Tactic Notation "iIntoEmpValid" open_constr(t) :=
  let rec go t :=
    (* We try two reduction tactics for the type of t before trying to
       specialize it. We first try the head normal form in order to
       unfold all the definition that could hide an entailment.  Then,
       we try the much weaker [eval cbv zeta], because entailment is
       not necessarilly opaque, and could be unfolded by [hnf].

       However, for calling type class search, we only use [cbv zeta]
       in order to make sure we do not unfold [bi_emp_valid]. *)
    let tT := type of t in
    first
      [ let tT' := eval hnf in tT in go_specialize t tT'
      | let tT' := eval cbv zeta in tT in go_specialize t tT'
      | let tT' := eval cbv zeta in tT in
        notypeclasses refine (as_emp_valid_1 tT _ _);
          [iSolveTC || fail 1 "iPoseProof: not a BI assertion"
          |exact t]]
  with go_specialize t tT :=
    lazymatch tT with                (* We do not use hnf of tT, because, if
                                        entailment is not opaque, then it would
                                        unfold it. *)
    | ?P → ?Q => let H := fresh in assert P as H; [|go uconstr:(t H); clear H]
    | ∀ _ : ?T, _ =>
      (* Put [T] inside an [id] to avoid TC inference from being invoked. *)
      (* This is a workarround for Coq bug #6583. *)
      let e := fresh in evar (e:id T);
      let e' := eval unfold e in e in clear e; go (t e')
    end
  in
  go t.

(* The tactic [tac] is called with a temporary fresh name [H]. The argument
[lazy_tc] denotes whether type class inference on the premises of [lem] should
be performed before (if false) or after (if true) [tac H] is called.

The tactic [iApply] uses lazy type class inference, so that evars can first be
instantiated by matching with the goal, whereas [iDestruct] does not, because
eliminations may not be performed when type classes have not been resolved.
*)
Local Ltac iPoseProofCore_go Htmp t goal_tac :=
  lazymatch type of t with
  | ident =>
    eapply tac_pose_proof_hyp with _ _ t _ Htmp _;
    [pm_reflexivity ||
     let t := pretty_ident t in
     fail "iPoseProof:" t "not found"
    |pm_reflexivity ||
     let Htmp := pretty_ident Htmp in
     fail "iPoseProof:" Htmp "not fresh"
    |goal_tac ()]
  | _ =>
    eapply tac_pose_proof with _ Htmp _; (* (j:=H) *)
    [iIntoEmpValid t
    |pm_reflexivity ||
     let Htmp := pretty_ident Htmp in
     fail "iPoseProof:" Htmp "not fresh"
    |goal_tac ()]
  end;
  try iSolveTC.
Tactic Notation "iPoseProofCore" open_constr(lem)
    "as" constr(p) constr(lazy_tc) tactic(tac) :=
  iStartProof;
  let Htmp := iFresh in
  let t := lazymatch lem with ITrm ?t ?xs ?pat => t | _ => lem end in
  let t := lazymatch type of t with string => constr:(INamed t) | _ => t end in
  let spec_tac _ :=
    lazymatch lem with
    | ITrm ?t ?xs ?pat => iSpecializeCore (ITrm Htmp xs pat) as p
    | _ => idtac
    end in
  lazymatch eval compute in lazy_tc with
  | true => iPoseProofCore_go Htmp t ltac:(fun _ => spec_tac (); last (tac Htmp))
  | false => iPoseProofCore_go Htmp t spec_tac; last (tac Htmp)
  end.

(** * Apply *)
Tactic Notation "iApplyHyp" constr(H) :=
  let rec go H := first
    [eapply tac_apply with _ H _ _ _;
      [pm_reflexivity
      |iSolveTC
      |pm_prettify (* reduce redexes created by instantiation *)
      ]
    |iSpecializePat H "[]"; last go H] in
  iExact H ||
  go H ||
  lazymatch iTypeOf H with
  | Some (_,?Q) => fail "iApply: cannot apply" Q
  end.

Tactic Notation "iApply" open_constr(lem) :=
  iPoseProofCore lem as false true (fun H => iApplyHyp H).

(** * Revert *)
Local Tactic Notation "iForallRevert" ident(x) :=
  let err x :=
    intros x;
    iMatchHyp (fun H P =>
      lazymatch P with
      | context [x] => fail 2 "iRevert:" x "is used in hypothesis" H
      end) in
  iStartProof;
  let A := type of x in
  lazymatch type of A with
  | Prop => revert x; first [apply tac_pure_revert|err x]
  | _ => revert x; first [apply tac_forall_revert|err x]
  end.

Tactic Notation "iRevert" constr(Hs) :=
  let rec go Hs :=
    lazymatch Hs with
    | [] => idtac
    | ESelPure :: ?Hs =>
       repeat match goal with x : _ |- _ => revert x end;
       go Hs
    | ESelIdent _ ?H :: ?Hs =>
       eapply tac_revert with _ H _ _; (* (i:=H2) *)
         [pm_reflexivity ||
          let H := pretty_ident H in
          fail "iRevert:" H "not found"
         |pm_reduce; go Hs]
    end in
  iStartProof; let Hs := iElaborateSelPat Hs in go Hs.

Tactic Notation "iRevert" "(" ident(x1) ")" :=
  iForallRevert x1.
Tactic Notation "iRevert" "(" ident(x1) ident(x2) ")" :=
  iForallRevert x2; iRevert ( x1 ).
Tactic Notation "iRevert" "(" ident(x1) ident(x2) ident(x3) ")" :=
  iForallRevert x3; iRevert ( x1 x2 ).
Tactic Notation "iRevert" "(" ident(x1) ident(x2) ident(x3) ident(x4) ")" :=
  iForallRevert x4; iRevert ( x1 x2 x3 ).
Tactic Notation "iRevert" "(" ident(x1) ident(x2) ident(x3) ident(x4)
    ident(x5) ")" :=
  iForallRevert x5; iRevert ( x1 x2 x3 x4 ).
Tactic Notation "iRevert" "(" ident(x1) ident(x2) ident(x3) ident(x4)
    ident(x5) ident(x6) ")" :=
  iForallRevert x6; iRevert ( x1 x2 x3 x4 x5 ).
Tactic Notation "iRevert" "(" ident(x1) ident(x2) ident(x3) ident(x4)
    ident(x5) ident(x6) ident(x7) ")" :=
  iForallRevert x7; iRevert ( x1 x2 x3 x4 x5 x6 ).
Tactic Notation "iRevert" "(" ident(x1) ident(x2) ident(x3) ident(x4)
    ident(x5) ident(x6) ident(x7) ident(x8) ")" :=
  iForallRevert x8; iRevert ( x1 x2 x3 x4 x5 x6 x7 ).

Tactic Notation "iRevert" "(" ident(x1) ")" constr(Hs) :=
  iRevert Hs; iRevert ( x1 ).
Tactic Notation "iRevert" "(" ident(x1) ident(x2) ")" constr(Hs) :=
  iRevert Hs; iRevert ( x1 x2 ).
Tactic Notation "iRevert" "(" ident(x1) ident(x2) ident(x3) ")" constr(Hs) :=
  iRevert Hs; iRevert ( x1 x2 x3 ).
Tactic Notation "iRevert" "(" ident(x1) ident(x2) ident(x3) ident(x4) ")"
    constr(Hs) :=
  iRevert Hs; iRevert ( x1 x2 x3 x4 ).
Tactic Notation "iRevert" "(" ident(x1) ident(x2) ident(x3) ident(x4)
    ident(x5) ")" constr(Hs) :=
  iRevert Hs; iRevert ( x1 x2 x3 x4 x5 ).
Tactic Notation "iRevert" "(" ident(x1) ident(x2) ident(x3) ident(x4)
    ident(x5) ident(x6) ")" constr(Hs) :=
  iRevert Hs; iRevert ( x1 x2 x3 x4 x5 x6 ).
Tactic Notation "iRevert" "(" ident(x1) ident(x2) ident(x3) ident(x4)
    ident(x5) ident(x6) ident(x7) ")" constr(Hs) :=
  iRevert Hs; iRevert ( x1 x2 x3 x4 x5 x6 x7 ).
Tactic Notation "iRevert" "(" ident(x1) ident(x2) ident(x3) ident(x4)
    ident(x5) ident(x6) ident(x7) ident(x8) ")" constr(Hs) :=
  iRevert Hs; iRevert ( x1 x2 x3 x4 x5 x6 x7 x8 ).

(** * Disjunction *)
Tactic Notation "iLeft" :=
  iStartProof;
  eapply tac_or_l;
    [iSolveTC ||
     let P := match goal with |- FromOr ?P _ _ => P end in
     fail "iLeft:" P "not a disjunction"
    |].
Tactic Notation "iRight" :=
  iStartProof;
  eapply tac_or_r;
    [iSolveTC ||
     let P := match goal with |- FromOr ?P _ _ => P end in
     fail "iRight:" P "not a disjunction"
    |].

Local Tactic Notation "iOrDestruct" constr(H) "as" constr(H1) constr(H2) :=
  eapply tac_or_destruct with _ _ H _ H1 H2 _ _ _; (* (i:=H) (j1:=H1) (j2:=H2) *)
    [pm_reflexivity ||
     let H := pretty_ident H in
     fail "iOrDestruct:" H "not found"
    |iSolveTC ||
     let P := match goal with |- IntoOr ?P _ _ => P end in
     fail "iOrDestruct: cannot destruct" P
    |pm_reflexivity ||
     let H1 := pretty_ident H1 in
     fail "iOrDestruct:" H1 "not fresh"
    |pm_reflexivity ||
     let H2 := pretty_ident H2 in
     fail "iOrDestruct:" H2 "not fresh"
    | |].

(** * Conjunction and separating conjunction *)
Tactic Notation "iSplit" :=
  iStartProof;
  eapply tac_and_split;
    [iSolveTC ||
     let P := match goal with |- FromAnd ?P _ _ => P end in
     fail "iSplit:" P "not a conjunction"| |].

Tactic Notation "iSplitL" constr(Hs) :=
  iStartProof;
  let Hs := words Hs in
  let Hs := eval vm_compute in (INamed <$> Hs) in
  eapply tac_sep_split with _ _ Left Hs _ _; (* (js:=Hs) *)
    [iSolveTC ||
     let P := match goal with |- FromSep _ ?P _ _ => P end in
     fail "iSplitL:" P "not a separating conjunction"
    |pm_reflexivity ||
     let Hs := iMissingHyps Hs in
     fail "iSplitL: hypotheses" Hs "not found"
    | |].

Tactic Notation "iSplitR" constr(Hs) :=
  iStartProof;
  let Hs := words Hs in
  let Hs := eval vm_compute in (INamed <$> Hs) in
  eapply tac_sep_split with _ _ Right Hs _ _; (* (js:=Hs) *)
    [iSolveTC ||
     let P := match goal with |- FromSep _ ?P _ _ => P end in
     fail "iSplitR:" P "not a separating conjunction"
    |pm_reflexivity ||
     let Hs := iMissingHyps Hs in
     fail "iSplitR: hypotheses" Hs "not found"
    | |].

Tactic Notation "iSplitL" := iSplitR "".
Tactic Notation "iSplitR" := iSplitL "".

Local Tactic Notation "iAndDestruct" constr(H) "as" constr(H1) constr(H2) :=
  eapply tac_and_destruct with _ H _ H1 H2 _ _ _; (* (i:=H) (j1:=H1) (j2:=H2) *)
    [pm_reflexivity ||
     let H := pretty_ident H in
     fail "iAndDestruct:" H "not found"
    |pm_reduce; iSolveTC ||
     let P :=
       lazymatch goal with
       | |- IntoSep ?P _ _ => P
       | |- IntoAnd _ ?P _ _ => P
       end in
     fail "iAndDestruct: cannot destruct" P
    |pm_reflexivity ||
     let H1 := pretty_ident H1 in
     let H2 := pretty_ident H2 in
     fail "iAndDestruct:" H1 "or" H2 " not fresh"|].

Local Tactic Notation "iAndDestructChoice" constr(H) "as" constr(d) constr(H') :=
  eapply tac_and_destruct_choice with _ H _ d H' _ _ _;
    [pm_reflexivity || fail "iAndDestructChoice:" H "not found"
    |pm_reduce; iSolveTC ||
     let P := match goal with |- TCOr (IntoAnd _ ?P _ _) _ => P end in
     fail "iAndDestructChoice: cannot destruct" P
    |pm_reflexivity ||
     let H' := pretty_ident H' in
     fail "iAndDestructChoice:" H' " not fresh"|].

(** * Existential *)
Tactic Notation "iExists" uconstr(x1) :=
  iStartProof;
  eapply tac_exist;
    [iSolveTC ||
     let P := match goal with |- FromExist ?P _ => P end in
     fail "iExists:" P "not an existential"
    |pm_prettify; eexists x1].

Tactic Notation "iExists" uconstr(x1) "," uconstr(x2) :=
  iExists x1; iExists x2.
Tactic Notation "iExists" uconstr(x1) "," uconstr(x2) "," uconstr(x3) :=
  iExists x1; iExists x2, x3.
Tactic Notation "iExists" uconstr(x1) "," uconstr(x2) "," uconstr(x3) ","
    uconstr(x4) :=
  iExists x1; iExists x2, x3, x4.
Tactic Notation "iExists" uconstr(x1) "," uconstr(x2) "," uconstr(x3) ","
    uconstr(x4) "," uconstr(x5) :=
  iExists x1; iExists x2, x3, x4, x5.
Tactic Notation "iExists" uconstr(x1) "," uconstr(x2) "," uconstr(x3) ","
    uconstr(x4) "," uconstr(x5) "," uconstr(x6) :=
  iExists x1; iExists x2, x3, x4, x5, x6.
Tactic Notation "iExists" uconstr(x1) "," uconstr(x2) "," uconstr(x3) ","
    uconstr(x4) "," uconstr(x5) "," uconstr(x6) "," uconstr(x7) :=
  iExists x1; iExists x2, x3, x4, x5, x6, x7.
Tactic Notation "iExists" uconstr(x1) "," uconstr(x2) "," uconstr(x3) ","
    uconstr(x4) "," uconstr(x5) "," uconstr(x6) "," uconstr(x7) ","
    uconstr(x8) :=
  iExists x1; iExists x2, x3, x4, x5, x6, x7, x8.

Local Tactic Notation "iExistDestruct" constr(H)
    "as" simple_intropattern(x) constr(Hx) :=
  eapply tac_exist_destruct with H _ Hx _ _; (* (i:=H) (j:=Hx) *)
    [pm_reflexivity ||
     let H := pretty_ident H in
     fail "iExistDestruct:" H "not found"
    |iSolveTC ||
     let P := match goal with |- IntoExist ?P _ => P end in
     fail "iExistDestruct: cannot destruct" P|];
  let y := fresh in
  intros y; eexists; split;
    [pm_reflexivity ||
     let Hx := pretty_ident Hx in
     fail "iExistDestruct:" Hx "not fresh"
    |revert y; intros x].

(** * Modality introduction *)
Tactic Notation "iModIntro" uconstr(sel) :=
  iStartProof;
  notypeclasses refine (tac_modal_intro _ sel _ _ _ _ _ _ _ _ _ _ _ _ _);
    [iSolveTC ||
     fail "iModIntro: the goal is not a modality"
    |iSolveTC ||
     let s := lazymatch goal with |- IntoModalPersistentEnv _ _ _ ?s => s end in
     lazymatch eval hnf in s with
     | MIEnvForall ?C => fail "iModIntro: persistent context does not satisfy" C
     | MIEnvIsEmpty => fail "iModIntro: persistent context is non-empty"
     end
    |iSolveTC ||
     let s := lazymatch goal with |- IntoModalSpatialEnv _ _ _ ?s _ => s end in
     lazymatch eval hnf in s with
     | MIEnvForall ?C => fail "iModIntro: spatial context does not satisfy" C
     | MIEnvIsEmpty => fail "iModIntro: spatial context is non-empty"
     end
    |pm_reduce; iSolveTC ||
     fail "iModIntro: cannot filter spatial context when goal is not absorbing"
    |pm_prettify (* reduce redexes created by instantiation *)
    ].
Tactic Notation "iModIntro" := iModIntro _.
Tactic Notation "iAlways" := iModIntro.

(** * Later *)
Tactic Notation "iNext" open_constr(n) := iModIntro (▷^n _)%I.
Tactic Notation "iNext" := iModIntro (▷^_ _)%I.

(** * Update modality *)
Tactic Notation "iModCore" constr(H) :=
  eapply tac_modal_elim with _ H _ _ _ _ _ _;
    [pm_reflexivity || fail "iMod:" H "not found"
    |iSolveTC ||
     let P := match goal with |- ElimModal _ _ _ ?P _ _ _ => P end in
     let Q := match goal with |- ElimModal _ _ _ _ _ ?Q _ => Q end in
     fail "iMod: cannot eliminate modality " P "in" Q
    |iSolveSideCondition
    |pm_reflexivity|].

(** * Basic destruct tactic *)
Tactic Notation "iDestructHyp" constr(H) "as" constr(pat) :=
  let rec go Hz pat :=
    lazymatch pat with
    | IAnom =>
       lazymatch Hz with
       | IAnon _ => idtac
       | INamed ?Hz => let Hz' := iFresh in iRename Hz into Hz'
       end
    | IDrop => iClearHyp Hz
    | IFrame => iFrameHyp Hz
    | IIdent ?y => iRename Hz into y
    | IList [[]] => iExFalso; iExact Hz
    | IList [[?pat1; IDrop]] => iAndDestructChoice Hz as Left Hz; go Hz pat1
    | IList [[IDrop; ?pat2]] => iAndDestructChoice Hz as Right Hz; go Hz pat2
    | IList [[?pat1; ?pat2]] =>
       let Hy := iFresh in iAndDestruct Hz as Hz Hy; go Hz pat1; go Hy pat2
    | IList [[?pat1];[?pat2]] => iOrDestruct Hz as Hz Hz; [go Hz pat1|go Hz pat2]
    | IPureElim => iPure Hz as ?
    | IRewrite Right => iPure Hz as ->
    | IRewrite Left => iPure Hz as <-
    | IAlwaysElim ?pat => iPersistent Hz; go Hz pat
    | IModalElim ?pat => iModCore Hz; go Hz pat
    | _ => fail "iDestruct:" pat "invalid"
    end in
  let rec find_pat found pats :=
    lazymatch pats with
    | [] =>
      lazymatch found with
      | true => pm_prettify (* post-tactic prettification *)
      | false => fail "iDestruct:" pat "should contain exactly one proper introduction pattern"
      end
    | ISimpl :: ?pats => simpl; find_pat found pats
    | IClear ?H :: ?pats => iClear H; find_pat found pats
    | IClearFrame ?H :: ?pats => iFrame H; find_pat found pats
    | ?pat :: ?pats =>
       lazymatch found with
       | false => go H pat; find_pat true pats
       | true => fail "iDestruct:" pat "should contain exactly one proper introduction pattern"
       end
    end in
  let pats := intro_pat.parse pat in
  find_pat false pats.

Tactic Notation "iDestructHyp" constr(H) "as" "(" simple_intropattern(x1) ")"
    constr(pat) :=
  iExistDestruct H as x1 H; iDestructHyp H as @ pat.
Tactic Notation "iDestructHyp" constr(H) "as" "(" simple_intropattern(x1)
    simple_intropattern(x2) ")" constr(pat) :=
  iExistDestruct H as x1 H; iDestructHyp H as ( x2 ) pat.
Tactic Notation "iDestructHyp" constr(H) "as" "(" simple_intropattern(x1)
    simple_intropattern(x2) simple_intropattern(x3) ")" constr(pat) :=
  iExistDestruct H as x1 H; iDestructHyp H as ( x2 x3 ) pat.
Tactic Notation "iDestructHyp" constr(H) "as" "(" simple_intropattern(x1)
    simple_intropattern(x2) simple_intropattern(x3) simple_intropattern(x4) ")"
    constr(pat) :=
  iExistDestruct H as x1 H; iDestructHyp H as ( x2 x3 x4 ) pat.
Tactic Notation "iDestructHyp" constr(H) "as" "(" simple_intropattern(x1)
    simple_intropattern(x2) simple_intropattern(x3) simple_intropattern(x4)
    simple_intropattern(x5) ")" constr(pat) :=
  iExistDestruct H as x1 H; iDestructHyp H as ( x2 x3 x4 x5 ) pat.
Tactic Notation "iDestructHyp" constr(H) "as" "(" simple_intropattern(x1)
    simple_intropattern(x2) simple_intropattern(x3) simple_intropattern(x4)
    simple_intropattern(x5) simple_intropattern(x6) ")" constr(pat) :=
  iExistDestruct H as x1 H; iDestructHyp H as ( x2 x3 x4 x5 x6 ) pat.
Tactic Notation "iDestructHyp" constr(H) "as" "(" simple_intropattern(x1)
    simple_intropattern(x2) simple_intropattern(x3) simple_intropattern(x4)
    simple_intropattern(x5) simple_intropattern(x6) simple_intropattern(x7) ")"
    constr(pat) :=
  iExistDestruct H as x1 H; iDestructHyp H as ( x2 x3 x4 x5 x6 x7 ) pat.
Tactic Notation "iDestructHyp" constr(H) "as" "(" simple_intropattern(x1)
    simple_intropattern(x2) simple_intropattern(x3) simple_intropattern(x4)
    simple_intropattern(x5) simple_intropattern(x6) simple_intropattern(x7)
    simple_intropattern(x8) ")" constr(pat) :=
  iExistDestruct H as x1 H; iDestructHyp H as ( x2 x3 x4 x5 x6 x7 x8 ) pat.

(** * Combinining hypotheses *)
Tactic Notation "iCombine" constr(Hs) "as" constr(pat) :=
  let Hs := words Hs in
  let Hs := eval vm_compute in (INamed <$> Hs) in
  let H := iFresh in
  eapply tac_combine with _ _ Hs _ _ H _;
    [pm_reflexivity ||
     let Hs := iMissingHyps Hs in
     fail "iCombine: hypotheses" Hs "not found"
    |iSolveTC
    |pm_reflexivity ||
     let H := pretty_ident H in
     fail "iCombine:" H "not fresh"
    |iDestructHyp H as pat].

Tactic Notation "iCombine" constr(H1) constr(H2) "as" constr(pat) :=
  iCombine [H1;H2] as pat.

(** * Introduction tactic *)
Ltac iIntros_go pats startproof :=
    lazymatch pats with
    | [] =>
      lazymatch startproof with
      | true => iStartProof
      | false => idtac
      end
    (* Optimizations to avoid generating fresh names *)
    | IPureElim :: ?pats => iIntro (?); iIntros_go pats startproof
    | IAlwaysElim (IIdent ?H) :: ?pats => iIntro #H; iIntros_go pats false
    | IDrop :: ?pats => iIntro _; iIntros_go pats startproof
    | IIdent ?H :: ?pats => iIntro H; iIntros_go pats startproof
    (* Introduction patterns that can only occur at the top-level *)
    | IPureIntro :: ?pats => iPureIntro; iIntros_go pats false
    | IAlwaysIntro :: ?pats => iAlways; iIntros_go pats false
    | IModalIntro :: ?pats => iModIntro; iIntros_go pats false
    | IForall :: ?pats => repeat iIntroForall; iIntros_go pats startproof
    | IAll :: ?pats => repeat (iIntroForall || iIntro); iIntros_go pats startproof
    (* Clearing and simplifying introduction patterns *)
    | ISimpl :: ?pats => simpl; iIntros_go pats startproof
    | IClear ?H :: ?pats => iClear H; iIntros_go pats false
    | IClearFrame ?H :: ?pats => iFrame H; iIntros_go pats false
    | IDone :: ?pats => try done; iIntros_go pats startproof
    (* Introduction + destruct *)
    | IAlwaysElim ?pat :: ?pats =>
       let H := iFresh in iIntro #H; iDestructHyp H as pat; iIntros_go pats false
    | ?pat :: ?pats =>
       let H := iFresh in iIntro H; iDestructHyp H as pat; iIntros_go pats false
    end.
Tactic Notation "iIntros" constr(pat) :=
  let pats := intro_pat.parse pat in iIntros_go pats true.
Tactic Notation "iIntros" := iIntros [IAll].

Tactic Notation "iIntros" "(" simple_intropattern(x1) ")" :=
  iIntro ( x1 ).
Tactic Notation "iIntros" "(" simple_intropattern(x1)
    simple_intropattern(x2) ")" :=
  iIntros ( x1 ); iIntro ( x2 ).
Tactic Notation "iIntros" "(" simple_intropattern(x1) simple_intropattern(x2)
    simple_intropattern(x3) ")" :=
  iIntros ( x1 x2 ); iIntro ( x3 ).
Tactic Notation "iIntros" "(" simple_intropattern(x1) simple_intropattern(x2)
    simple_intropattern(x3) simple_intropattern(x4) ")" :=
  iIntros ( x1 x2 x3 ); iIntro ( x4 ).
Tactic Notation "iIntros" "(" simple_intropattern(x1) simple_intropattern(x2)
    simple_intropattern(x3) simple_intropattern(x4) simple_intropattern(x5) ")" :=
  iIntros ( x1 x2 x3 x4 ); iIntro ( x5 ).
Tactic Notation "iIntros" "(" simple_intropattern(x1) simple_intropattern(x2)
    simple_intropattern(x3) simple_intropattern(x4) simple_intropattern(x5)
    simple_intropattern(x6) ")" :=
  iIntros ( x1 x2 x3 x4 x5 ); iIntro ( x6 ).
Tactic Notation "iIntros" "(" simple_intropattern(x1) simple_intropattern(x2)
    simple_intropattern(x3) simple_intropattern(x4) simple_intropattern(x5)
    simple_intropattern(x6) simple_intropattern(x7) ")" :=
  iIntros ( x1 x2 x3 x4 x5 x6 ); iIntro ( x7 ).
Tactic Notation "iIntros" "(" simple_intropattern(x1) simple_intropattern(x2)
    simple_intropattern(x3) simple_intropattern(x4) simple_intropattern(x5)
    simple_intropattern(x6) simple_intropattern(x7) simple_intropattern(x8) ")" :=
  iIntros ( x1 x2 x3 x4 x5 x6 x7 ); iIntro ( x8 ).
Tactic Notation "iIntros" "(" simple_intropattern(x1) simple_intropattern(x2)
    simple_intropattern(x3) simple_intropattern(x4) simple_intropattern(x5)
    simple_intropattern(x6) simple_intropattern(x7) simple_intropattern(x8)
    simple_intropattern(x9) ")" :=
  iIntros ( x1 x2 x3 x4 x5 x6 x7 x8 ); iIntro ( x9 ).
Tactic Notation "iIntros" "(" simple_intropattern(x1) simple_intropattern(x2)
    simple_intropattern(x3) simple_intropattern(x4) simple_intropattern(x5)
    simple_intropattern(x6) simple_intropattern(x7) simple_intropattern(x8)
    simple_intropattern(x9) simple_intropattern(x10) ")" :=
  iIntros ( x1 x2 x3 x4 x5 x6 x7 x8 x9 ); iIntro ( x10 ).
Tactic Notation "iIntros" "(" simple_intropattern(x1) simple_intropattern(x2)
    simple_intropattern(x3) simple_intropattern(x4) simple_intropattern(x5)
    simple_intropattern(x6) simple_intropattern(x7) simple_intropattern(x8)
    simple_intropattern(x9) simple_intropattern(x10) simple_intropattern(x11) ")" :=
  iIntros ( x1 x2 x3 x4 x5 x6 x7 x8 x9 x10 ); iIntro ( x11 ).
Tactic Notation "iIntros" "(" simple_intropattern(x1) simple_intropattern(x2)
    simple_intropattern(x3) simple_intropattern(x4) simple_intropattern(x5)
    simple_intropattern(x6) simple_intropattern(x7) simple_intropattern(x8)
    simple_intropattern(x9) simple_intropattern(x10) simple_intropattern(x11)
    simple_intropattern(x12) ")" :=
  iIntros ( x1 x2 x3 x4 x5 x6 x7 x8 x9 x10 x11 ); iIntro ( x12 ).

Tactic Notation "iIntros" "(" simple_intropattern(x1) ")" constr(p) :=
  iIntros ( x1 ); iIntros p.
Tactic Notation "iIntros" "(" simple_intropattern(x1) simple_intropattern(x2)
    ")" constr(p) :=
  iIntros ( x1 x2 ); iIntros p.
Tactic Notation "iIntros" "(" simple_intropattern(x1) simple_intropattern(x2)
    simple_intropattern(x3) ")" constr(p) :=
  iIntros ( x1 x2 x3 ); iIntros p.
Tactic Notation "iIntros" "(" simple_intropattern(x1) simple_intropattern(x2)
    simple_intropattern(x3) simple_intropattern(x4) ")" constr(p) :=
  iIntros ( x1 x2 x3 x4 ); iIntros p.
Tactic Notation "iIntros" "(" simple_intropattern(x1) simple_intropattern(x2)
    simple_intropattern(x3) simple_intropattern(x4) simple_intropattern(x5)
    ")" constr(p) :=
  iIntros ( x1 x2 x3 x4 x5 ); iIntros p.
Tactic Notation "iIntros" "(" simple_intropattern(x1) simple_intropattern(x2)
    simple_intropattern(x3) simple_intropattern(x4) simple_intropattern(x5)
    simple_intropattern(x6) ")" constr(p) :=
  iIntros ( x1 x2 x3 x4 x5 x6 ); iIntros p.
Tactic Notation "iIntros" "(" simple_intropattern(x1) simple_intropattern(x2)
    simple_intropattern(x3) simple_intropattern(x4) simple_intropattern(x5)
    simple_intropattern(x6) simple_intropattern(x7) ")" constr(p) :=
  iIntros ( x1 x2 x3 x4 x5 x6 x7 ); iIntros p.
Tactic Notation "iIntros" "(" simple_intropattern(x1) simple_intropattern(x2)
    simple_intropattern(x3) simple_intropattern(x4) simple_intropattern(x5)
    simple_intropattern(x6) simple_intropattern(x7) simple_intropattern(x8)
    ")" constr(p) :=
  iIntros ( x1 x2 x3 x4 x5 x6 x7 x8 ); iIntros p.
Tactic Notation "iIntros" "(" simple_intropattern(x1) simple_intropattern(x2)
    simple_intropattern(x3) simple_intropattern(x4) simple_intropattern(x5)
    simple_intropattern(x6) simple_intropattern(x7) simple_intropattern(x8)
    simple_intropattern(x9) ")" constr(p) :=
  iIntros ( x1 x2 x3 x4 x5 x6 x7 x8 x9 ); iIntros p.
Tactic Notation "iIntros" "(" simple_intropattern(x1) simple_intropattern(x2)
    simple_intropattern(x3) simple_intropattern(x4) simple_intropattern(x5)
    simple_intropattern(x6) simple_intropattern(x7) simple_intropattern(x8)
    simple_intropattern(x9) simple_intropattern(x10) ")" constr(p) :=
  iIntros ( x1 x2 x3 x4 x5 x6 x7 x8 x9 x10 ); iIntros p.
Tactic Notation "iIntros" "(" simple_intropattern(x1) simple_intropattern(x2)
    simple_intropattern(x3) simple_intropattern(x4) simple_intropattern(x5)
    simple_intropattern(x6) simple_intropattern(x7) simple_intropattern(x8)
    simple_intropattern(x9) simple_intropattern(x10) simple_intropattern(x11)
    ")" constr(p) :=
  iIntros ( x1 x2 x3 x4 x5 x6 x7 x8 x9 x10 x11 ); iIntros p.
Tactic Notation "iIntros" "(" simple_intropattern(x1) simple_intropattern(x2)
    simple_intropattern(x3) simple_intropattern(x4) simple_intropattern(x5)
    simple_intropattern(x6) simple_intropattern(x7) simple_intropattern(x8)
    simple_intropattern(x9) simple_intropattern(x10) simple_intropattern(x11)
    simple_intropattern(x12) ")" constr(p) :=
  iIntros ( x1 x2 x3 x4 x5 x6 x7 x8 x9 x10 x11 x12 ); iIntros p.

Tactic Notation "iIntros" constr(p) "(" simple_intropattern(x1) ")" :=
  iIntros p; iIntros ( x1 ).
Tactic Notation "iIntros" constr(p) "(" simple_intropattern(x1)
    simple_intropattern(x2) ")" :=
  iIntros p; iIntros ( x1 x2 ).
Tactic Notation "iIntros" constr(p) "(" simple_intropattern(x1)
    simple_intropattern(x2) simple_intropattern(x3) ")" :=
  iIntros p; iIntros ( x1 x2 x3 ).
Tactic Notation "iIntros" constr(p) "(" simple_intropattern(x1)
    simple_intropattern(x2) simple_intropattern(x3) simple_intropattern(x4) ")" :=
  iIntros p; iIntros ( x1 x2 x3 x4 ).
Tactic Notation "iIntros" constr(p) "(" simple_intropattern(x1)
    simple_intropattern(x2) simple_intropattern(x3) simple_intropattern(x4)
    simple_intropattern(x5) ")" :=
  iIntros p; iIntros ( x1 x2 x3 x4 x5 ).
Tactic Notation "iIntros" constr(p) "(" simple_intropattern(x1)
    simple_intropattern(x2) simple_intropattern(x3) simple_intropattern(x4)
    simple_intropattern(x5) simple_intropattern(x6) ")" :=
  iIntros p; iIntros ( x1 x2 x3 x4 x5 x6 ).
Tactic Notation "iIntros" constr(p) "(" simple_intropattern(x1)
    simple_intropattern(x2) simple_intropattern(x3) simple_intropattern(x4)
    simple_intropattern(x5) simple_intropattern(x6) simple_intropattern(x7) ")" :=
  iIntros p; iIntros ( x1 x2 x3 x4 x5 x6 x7 ).
Tactic Notation "iIntros" constr(p) "(" simple_intropattern(x1)
    simple_intropattern(x2) simple_intropattern(x3) simple_intropattern(x4)
    simple_intropattern(x5) simple_intropattern(x6) simple_intropattern(x7)
    simple_intropattern(x8) ")" :=
  iIntros p; iIntros ( x1 x2 x3 x4 x5 x6 x7 x8 ).
Tactic Notation "iIntros" constr(p) "(" simple_intropattern(x1)
    simple_intropattern(x2) simple_intropattern(x3) simple_intropattern(x4)
    simple_intropattern(x5) simple_intropattern(x6) simple_intropattern(x7)
    simple_intropattern(x8) simple_intropattern(x9) ")" :=
  iIntros p; iIntros ( x1 x2 x3 x4 x5 x6 x7 x8 x9 ).
Tactic Notation "iIntros" constr(p) "(" simple_intropattern(x1)
    simple_intropattern(x2) simple_intropattern(x3) simple_intropattern(x4)
    simple_intropattern(x5) simple_intropattern(x6) simple_intropattern(x7)
    simple_intropattern(x8) simple_intropattern(x9) simple_intropattern(x10) ")" :=
  iIntros p; iIntros ( x1 x2 x3 x4 x5 x6 x7 x8 x9 x10 ).
Tactic Notation "iIntros" constr(p) "(" simple_intropattern(x1)
    simple_intropattern(x2) simple_intropattern(x3) simple_intropattern(x4)
    simple_intropattern(x5) simple_intropattern(x6) simple_intropattern(x7)
    simple_intropattern(x8) simple_intropattern(x9) simple_intropattern(x10)
    simple_intropattern(x11) ")" :=
  iIntros p; iIntros ( x1 x2 x3 x4 x5 x6 x7 x8 x9 x10 x11 ).
Tactic Notation "iIntros" constr(p) "(" simple_intropattern(x1)
    simple_intropattern(x2) simple_intropattern(x3) simple_intropattern(x4)
    simple_intropattern(x5) simple_intropattern(x6) simple_intropattern(x7)
    simple_intropattern(x8) simple_intropattern(x9) simple_intropattern(x10)
    simple_intropattern(x11) simple_intropattern(x12) ")" :=
  iIntros p; iIntros ( x1 x2 x3 x4 x5 x6 x7 x8 x9 x10 x11 x12 ).

Tactic Notation "iIntros" constr(p) "(" simple_intropattern(x1) ")" constr(p2) :=
  iIntros p; iIntros ( x1 ); iIntros p2.
Tactic Notation "iIntros" constr(p) "(" simple_intropattern(x1)
    simple_intropattern(x2) ")" constr(p2) :=
  iIntros p; iIntros ( x1 x2 ); iIntros p2.
Tactic Notation "iIntros" constr(p) "(" simple_intropattern(x1)
    simple_intropattern(x2) simple_intropattern(x3) ")" constr(p2) :=
  iIntros p; iIntros ( x1 x2 x3 ); iIntros p2.
Tactic Notation "iIntros" constr(p) "(" simple_intropattern(x1)
    simple_intropattern(x2) simple_intropattern(x3) simple_intropattern(x4)
    ")" constr(p2) :=
  iIntros p; iIntros ( x1 x2 x3 x4 ); iIntros p2.
Tactic Notation "iIntros" constr(p) "(" simple_intropattern(x1)
    simple_intropattern(x2) simple_intropattern(x3) simple_intropattern(x4)
    simple_intropattern(x5) ")" constr(p2) :=
  iIntros p; iIntros ( x1 x2 x3 x4 x5 ); iIntros p2.
Tactic Notation "iIntros" constr(p) "(" simple_intropattern(x1)
    simple_intropattern(x2) simple_intropattern(x3) simple_intropattern(x4)
    simple_intropattern(x5) simple_intropattern(x6) ")" constr(p2) :=
  iIntros p; iIntros ( x1 x2 x3 x4 x5 x6 ); iIntros p2.
Tactic Notation "iIntros" constr(p) "(" simple_intropattern(x1)
    simple_intropattern(x2) simple_intropattern(x3) simple_intropattern(x4)
    simple_intropattern(x5) simple_intropattern(x6) simple_intropattern(x7)
    ")" constr(p2) :=
  iIntros p; iIntros ( x1 x2 x3 x4 x5 x6 x7 ); iIntros p2.
Tactic Notation "iIntros" constr(p) "(" simple_intropattern(x1)
    simple_intropattern(x2) simple_intropattern(x3) simple_intropattern(x4)
    simple_intropattern(x5) simple_intropattern(x6) simple_intropattern(x7)
    simple_intropattern(x8) ")" constr(p2) :=
  iIntros p; iIntros ( x1 x2 x3 x4 x5 x6 x7 x8 ); iIntros p2.
Tactic Notation "iIntros" constr(p) "(" simple_intropattern(x1)
    simple_intropattern(x2) simple_intropattern(x3) simple_intropattern(x4)
    simple_intropattern(x5) simple_intropattern(x6) simple_intropattern(x7)
    simple_intropattern(x8) simple_intropattern(x9) ")" constr(p2) :=
  iIntros p; iIntros ( x1 x2 x3 x4 x5 x6 x7 x8 x9 ); iIntros p2.
Tactic Notation "iIntros" constr(p) "(" simple_intropattern(x1)
    simple_intropattern(x2) simple_intropattern(x3) simple_intropattern(x4)
    simple_intropattern(x5) simple_intropattern(x6) simple_intropattern(x7)
    simple_intropattern(x8) simple_intropattern(x9) simple_intropattern(x10)
    ")" constr(p2) :=
  iIntros p; iIntros ( x1 x2 x3 x4 x5 x6 x7 x8 x9 x10 ); iIntros p2.
Tactic Notation "iIntros" constr(p) "(" simple_intropattern(x1)
    simple_intropattern(x2) simple_intropattern(x3) simple_intropattern(x4)
    simple_intropattern(x5) simple_intropattern(x6) simple_intropattern(x7)
    simple_intropattern(x8) simple_intropattern(x9) simple_intropattern(x10)
    simple_intropattern(x11) ")" constr(p2) :=
  iIntros p; iIntros ( x1 x2 x3 x4 x5 x6 x7 x8 x9 x10 x11 ); iIntros p2.
Tactic Notation "iIntros" constr(p) "(" simple_intropattern(x1)
    simple_intropattern(x2) simple_intropattern(x3) simple_intropattern(x4)
    simple_intropattern(x5) simple_intropattern(x6) simple_intropattern(x7)
    simple_intropattern(x8) simple_intropattern(x9) simple_intropattern(x10)
    simple_intropattern(x11) simple_intropattern(x12) ")" constr(p2) :=
  iIntros p; iIntros ( x1 x2 x3 x4 x5 x6 x7 x8 x9 x10 x11 x12 ); iIntros p2.


(* Used for generalization in iInduction and iLöb *)
Tactic Notation "iRevertIntros" constr(Hs) "with" tactic(tac) :=
  let rec go Hs :=
    lazymatch Hs with
    | [] => tac
    | ESelPure :: ?Hs => fail "iRevertIntros: % not supported"
    | ESelIdent ?p ?H :: ?Hs =>
       iRevert H; go Hs;
       let H' :=
         match p with true => constr:([IAlwaysElim (IIdent H)]) | false => H end in
       iIntros H'
    end in
  try iStartProof; let Hs := iElaborateSelPat Hs in go Hs.

Tactic Notation "iRevertIntros" "(" ident(x1) ")" constr(Hs) "with" tactic(tac):=
  iRevertIntros Hs with (iRevert (x1); tac; iIntros (x1)).
Tactic Notation "iRevertIntros" "(" ident(x1) ident(x2) ")" constr(Hs)
    "with" tactic(tac):=
  iRevertIntros Hs with (iRevert (x1 x2); tac; iIntros (x1 x2)).
Tactic Notation "iRevertIntros" "(" ident(x1) ident(x2) ident(x3) ")" constr(Hs)
    "with" tactic(tac):=
  iRevertIntros Hs with (iRevert (x1 x2 x3); tac; iIntros (x1 x2 x3)).
Tactic Notation "iRevertIntros" "(" ident(x1) ident(x2) ident(x3) ident(x4) ")"
    constr(Hs) "with" tactic(tac):=
  iRevertIntros Hs with (iRevert (x1 x2 x3 x4); tac; iIntros (x1 x2 x3 x4)).
Tactic Notation "iRevertIntros" "(" ident(x1) ident(x2) ident(x3) ident(x4)
    ident(x5) ")" constr(Hs) "with" tactic(tac):=
  iRevertIntros Hs with (iRevert (x1 x2 x3 x4 x5); tac; iIntros (x1 x2 x3 x4 x5)).
Tactic Notation "iRevertIntros" "(" ident(x1) ident(x2) ident(x3) ident(x4)
    ident(x5) ident(x6) ")" constr(Hs) "with" tactic(tac):=
  iRevertIntros Hs with (iRevert (x1 x2 x3 x4 x5 x6);
    tac; iIntros (x1 x2 x3 x4 x5 x6)).
Tactic Notation "iRevertIntros" "(" ident(x1) ident(x2) ident(x3) ident(x4)
    ident(x5) ident(x6) ident(x7) ")" constr(Hs) "with" tactic(tac):=
  iRevertIntros Hs with (iRevert (x1 x2 x3 x4 x5 x6 x7);
    tac; iIntros (x1 x2 x3 x4 x5 x6 x7)).
Tactic Notation "iRevertIntros" "(" ident(x1) ident(x2) ident(x3) ident(x4)
    ident(x5) ident(x6) ident(x7) ident(x8) ")" constr(Hs) "with" tactic(tac):=
  iRevertIntros Hs with (iRevert (x1 x2 x3 x4 x5 x6 x7 x8);
    tac; iIntros (x1 x2 x3 x4 x5 x6 x7 x8)).

Tactic Notation "iRevertIntros" "with" tactic(tac) :=
  iRevertIntros "" with tac.
Tactic Notation "iRevertIntros" "(" ident(x1) ")" "with" tactic(tac):=
  iRevertIntros (x1) "" with tac.
Tactic Notation "iRevertIntros" "(" ident(x1) ident(x2) ")" "with" tactic(tac):=
  iRevertIntros (x1 x2) "" with tac.
Tactic Notation "iRevertIntros" "(" ident(x1) ident(x2) ident(x3) ")"
    "with" tactic(tac):=
  iRevertIntros (x1 x2 x3) "" with tac.
Tactic Notation "iRevertIntros" "(" ident(x1) ident(x2) ident(x3) ident(x4) ")"
    "with" tactic(tac):=
  iRevertIntros (x1 x2 x3 x4) "" with tac.
Tactic Notation "iRevertIntros" "(" ident(x1) ident(x2) ident(x3) ident(x4)
    ident(x5) ")" "with" tactic(tac):=
  iRevertIntros (x1 x2 x3 x4 x5) "" with tac.
Tactic Notation "iRevertIntros" "(" ident(x1) ident(x2) ident(x3) ident(x4)
    ident(x5) ident(x6) ")" "with" tactic(tac):=
  iRevertIntros (x1 x2 x3 x4 x5 x6) "" with tac.
Tactic Notation "iRevertIntros" "(" ident(x1) ident(x2) ident(x3) ident(x4)
    ident(x5) ident(x6) ident(x7) ")" "with" tactic(tac):=
  iRevertIntros (x1 x2 x3 x4 x5 x6 x7) "" with tac.
Tactic Notation "iRevertIntros" "(" ident(x1) ident(x2) ident(x3) ident(x4)
    ident(x5) ident(x6) ident(x7) ident(x8) ")" "with" tactic(tac):=
  iRevertIntros (x1 x2 x3 x4 x5 x6 x7 x8) "" with tac.

(** * Destruct tactic *)
Class CopyDestruct {PROP : bi} (P : PROP).
Arguments CopyDestruct {_} _%I.
Hint Mode CopyDestruct + ! : typeclass_instances.

Instance copy_destruct_forall {PROP : bi} {A} (Φ : A → PROP) : CopyDestruct (∀ x, Φ x).
Instance copy_destruct_impl {PROP : bi} (P Q : PROP) :
  CopyDestruct Q → CopyDestruct (P → Q).
Instance copy_destruct_wand {PROP : bi} (P Q : PROP) :
  CopyDestruct Q → CopyDestruct (P -∗ Q).
Instance copy_destruct_affinely {PROP : bi} (P : PROP) :
  CopyDestruct P → CopyDestruct (<affine> P).
Instance copy_destruct_persistently {PROP : bi} (P : PROP) :
  CopyDestruct P → CopyDestruct (<pers> P).

Tactic Notation "iDestructCore" open_constr(lem) "as" constr(p) tactic(tac) :=
  let ident :=
    lazymatch type of lem with
    | ident => constr:(Some lem)
    | string => constr:(Some (INamed lem))
    | iTrm =>
       lazymatch lem with
       | @iTrm ident ?H _ _ => constr:(Some H)
       | @iTrm string ?H _ _ => constr:(Some (INamed H))
       | _ => constr:(@None ident)
       end
    | _ => constr:(@None ident)
    end in
  let intro_destruct n :=
    let rec go n' :=
      lazymatch n' with
      | 0 => fail "iDestruct: cannot introduce" n "hypotheses"
      | 1 => repeat iIntroForall; let H := iFresh in iIntro H; tac H
      | S ?n' => repeat iIntroForall; let H := iFresh in iIntro H; go n'
      end in
    intros; go n in
  lazymatch type of lem with
  | nat => intro_destruct lem
  | Z => (* to make it work in Z_scope. We should just be able to bind
     tactic notation arguments to notation scopes. *)
     let n := eval compute in (Z.to_nat lem) in intro_destruct n
  | _ =>
     (* Only copy the hypothesis in case there is a [CopyDestruct] instance.
     Also, rule out cases in which it does not make sense to copy, namely when
     destructing a lemma (instead of a hypothesis) or a spatial hyopthesis
     (which cannot be kept). *)
     iStartProof;
     lazymatch ident with
     | None => iPoseProofCore lem as p false tac
     | Some ?H =>
        lazymatch iTypeOf H with
        | None =>
          let H := pretty_ident H in
          fail "iDestruct:" H "not found"
        | Some (true, ?P) =>
           (* persistent hypothesis, check for a CopyDestruct instance *)
           tryif (let dummy := constr:(_ : CopyDestruct P) in idtac)
           then (iPoseProofCore lem as p false tac)
           else (iSpecializeCore lem as p; last (tac H))
        | Some (false, ?P) =>
           (* spatial hypothesis, cannot copy *)
           iSpecializeCore lem as p; last (tac H)
        end
     end
  end.

Tactic Notation "iDestruct" open_constr(lem) "as" constr(pat) :=
  iDestructCore lem as pat (fun H => iDestructHyp H as pat).
Tactic Notation "iDestruct" open_constr(lem) "as" "(" simple_intropattern(x1) ")"
    constr(pat) :=
  iDestructCore lem as pat (fun H => iDestructHyp H as ( x1 ) pat).
Tactic Notation "iDestruct" open_constr(lem) "as" "(" simple_intropattern(x1)
    simple_intropattern(x2) ")" constr(pat) :=
  iDestructCore lem as pat (fun H => iDestructHyp H as ( x1 x2 ) pat).
Tactic Notation "iDestruct" open_constr(lem) "as" "(" simple_intropattern(x1)
    simple_intropattern(x2) simple_intropattern(x3) ")" constr(pat) :=
  iDestructCore lem as pat (fun H => iDestructHyp H as ( x1 x2 x3 ) pat).
Tactic Notation "iDestruct" open_constr(lem) "as" "(" simple_intropattern(x1)
    simple_intropattern(x2) simple_intropattern(x3) simple_intropattern(x4) ")"
    constr(pat) :=
  iDestructCore lem as pat (fun H => iDestructHyp H as ( x1 x2 x3 x4 ) pat).
Tactic Notation "iDestruct" open_constr(lem) "as" "(" simple_intropattern(x1)
    simple_intropattern(x2) simple_intropattern(x3) simple_intropattern(x4)
    simple_intropattern(x5) ")" constr(pat) :=
  iDestructCore lem as pat (fun H => iDestructHyp H as ( x1 x2 x3 x4 x5 ) pat).
Tactic Notation "iDestruct" open_constr(lem) "as" "(" simple_intropattern(x1)
    simple_intropattern(x2) simple_intropattern(x3) simple_intropattern(x4)
    simple_intropattern(x5) simple_intropattern(x6) ")" constr(pat) :=
  iDestructCore lem as pat (fun H => iDestructHyp H as ( x1 x2 x3 x4 x5 x6 ) pat).
Tactic Notation "iDestruct" open_constr(lem) "as" "(" simple_intropattern(x1)
    simple_intropattern(x2) simple_intropattern(x3) simple_intropattern(x4)
    simple_intropattern(x5) simple_intropattern(x6) simple_intropattern(x7) ")"
    constr(pat) :=
  iDestructCore lem as pat (fun H => iDestructHyp H as ( x1 x2 x3 x4 x5 x6 x7 ) pat).
Tactic Notation "iDestruct" open_constr(lem) "as" "(" simple_intropattern(x1)
    simple_intropattern(x2) simple_intropattern(x3) simple_intropattern(x4)
    simple_intropattern(x5) simple_intropattern(x6) simple_intropattern(x7)
    simple_intropattern(x8) ")" constr(pat) :=
  iDestructCore lem as pat (fun H => iDestructHyp H as ( x1 x2 x3 x4 x5 x6 x7 x8 ) pat).

Tactic Notation "iDestruct" open_constr(lem) "as" "%" simple_intropattern(pat) :=
  iDestructCore lem as true (fun H => iPure H as pat).

Tactic Notation "iPoseProof" open_constr(lem) "as" constr(pat) :=
  iPoseProofCore lem as pat false (fun H => iDestructHyp H as pat).
Tactic Notation "iPoseProof" open_constr(lem) "as" "(" simple_intropattern(x1) ")"
    constr(pat) :=
  iPoseProofCore lem as pat false (fun H => iDestructHyp H as ( x1 ) pat).
Tactic Notation "iPoseProof" open_constr(lem) "as" "(" simple_intropattern(x1)
    simple_intropattern(x2) ")" constr(pat) :=
  iPoseProofCore lem as pat false (fun H => iDestructHyp H as ( x1 x2 ) pat).
Tactic Notation "iPoseProof" open_constr(lem) "as" "(" simple_intropattern(x1)
    simple_intropattern(x2) simple_intropattern(x3) ")" constr(pat) :=
  iPoseProofCore lem as pat false (fun H => iDestructHyp H as ( x1 x2 x3 ) pat).
Tactic Notation "iPoseProof" open_constr(lem) "as" "(" simple_intropattern(x1)
    simple_intropattern(x2) simple_intropattern(x3) simple_intropattern(x4) ")"
    constr(pat) :=
  iPoseProofCore lem as pat false (fun H => iDestructHyp H as ( x1 x2 x3 x4 ) pat).
Tactic Notation "iPoseProof" open_constr(lem) "as" "(" simple_intropattern(x1)
    simple_intropattern(x2) simple_intropattern(x3) simple_intropattern(x4)
    simple_intropattern(x5) ")" constr(pat) :=
  iPoseProofCore lem as pat false (fun H => iDestructHyp H as ( x1 x2 x3 x4 x5 ) pat).
Tactic Notation "iPoseProof" open_constr(lem) "as" "(" simple_intropattern(x1)
    simple_intropattern(x2) simple_intropattern(x3) simple_intropattern(x4)
    simple_intropattern(x5) simple_intropattern(x6) ")" constr(pat) :=
  iPoseProofCore lem as pat false (fun H => iDestructHyp H as ( x1 x2 x3 x4 x5 x6 ) pat).
Tactic Notation "iPoseProof" open_constr(lem) "as" "(" simple_intropattern(x1)
    simple_intropattern(x2) simple_intropattern(x3) simple_intropattern(x4)
    simple_intropattern(x5) simple_intropattern(x6) simple_intropattern(x7) ")"
    constr(pat) :=
  iPoseProofCore lem as pat false (fun H => iDestructHyp H as ( x1 x2 x3 x4 x5 x6 x7 ) pat).
Tactic Notation "iPoseProof" open_constr(lem) "as" "(" simple_intropattern(x1)
    simple_intropattern(x2) simple_intropattern(x3) simple_intropattern(x4)
    simple_intropattern(x5) simple_intropattern(x6) simple_intropattern(x7)
    simple_intropattern(x8) ")" constr(pat) :=
  iPoseProofCore lem as pat false (fun H => iDestructHyp H as ( x1 x2 x3 x4 x5 x6 x7 x8 ) pat).

(** * Induction *)
(* An invocation of [iInduction (x) as pat IH forall (x1...xn) Hs] will
result in the following actions:

- Revert the proofmode hypotheses [Hs]
- Revert all remaining spatial hypotheses and the remaining persistent
  hypotheses containing the induction variable [x]
- Revert the pure hypotheses [x1..xn]

- Actuall perform induction

- Introduce thee pure hypotheses [x1..xn]
- Introduce the spatial hypotheses and persistent hypotheses involving [x]
- Introduce the proofmode hypotheses [Hs]
*)
Tactic Notation "iInductionCore" tactic(tac) "as" constr(IH) :=
  let rec fix_ihs rev_tac :=
    lazymatch goal with
    | H : context [envs_entails _ _] |- _ =>
       eapply (tac_revert_ih _ _ _ H _);
         [pm_reflexivity
          || fail "iInduction: spatial context not empty, this should not happen"
         |clear H];
       fix_ihs ltac:(fun j =>
         let IH' := eval vm_compute in
           match j with 0%N => IH | _ => IH +:+ pretty j end in
         iIntros [IAlwaysElim (IIdent IH')];
         let j := eval vm_compute in (1 + j)%N in
         rev_tac j)
    | _ => rev_tac 0%N
    end in
  tac; fix_ihs ltac:(fun _ => idtac).

Ltac iHypsContaining x :=
  let rec go Γ x Hs :=
    lazymatch Γ with
    | Enil => constr:(Hs)
    | Esnoc ?Γ ?H ?Q =>
       match Q with
       | context [x] => go Γ x (H :: Hs)
       | _ => go Γ x Hs
       end
     end in
  let Γp := lazymatch goal with |- envs_entails (Envs ?Γp _ _) _ => Γp end in
  let Γs := lazymatch goal with |- envs_entails (Envs _ ?Γs _) _ => Γs end in
  let Hs := go Γp x (@nil ident) in go Γs x Hs.

Tactic Notation "iInductionRevert" constr(x) constr(Hs) "with" tactic(tac) :=
  iRevertIntros Hs with (
    iRevertIntros "∗" with (
      idtac;
      let Hsx := iHypsContaining x in
      iRevertIntros Hsx with tac
    )
  ).

Tactic Notation "iInduction" constr(x) "as" simple_intropattern(pat) constr(IH) :=
  iInductionRevert x "" with (iInductionCore (induction x as pat) as IH).
Tactic Notation "iInduction" constr(x) "as" simple_intropattern(pat) constr(IH)
    "forall" "(" ident(x1) ")" :=
  iInductionRevert x "" with (
    iRevertIntros(x1) "" with (iInductionCore (induction x as pat) as IH)).
Tactic Notation "iInduction" constr(x) "as" simple_intropattern(pat) constr(IH)
    "forall" "(" ident(x1) ident(x2) ")" :=
  iInductionRevert x "" with
    (iRevertIntros(x1 x2) "" with (iInductionCore (induction x as pat) as IH)).
Tactic Notation "iInduction" constr(x) "as" simple_intropattern(pat) constr(IH)
    "forall" "(" ident(x1) ident(x2) ident(x3) ")" :=
  iInductionRevert x "" with
    (iRevertIntros(x1 x2 x3) "" with (iInductionCore (induction x as pat) as IH)).
Tactic Notation "iInduction" constr(x) "as" simple_intropattern(pat) constr(IH)
    "forall" "(" ident(x1) ident(x2) ident(x3) ident(x4) ")" :=
  iInductionRevert x "" with
    (iRevertIntros(x1 x2 x3 x4) "" with (iInductionCore (induction x as pat) as IH)).
Tactic Notation "iInduction" constr(x) "as" simple_intropattern(pat) constr(IH)
    "forall" "(" ident(x1) ident(x2) ident(x3) ident(x4) ident(x5) ")" :=
  iInductionRevert x "" with
    (iRevertIntros(x1 x2 x3 x4 x5) "" with (iInductionCore (induction x as pat) as IH)).
Tactic Notation "iInduction" constr(x) "as" simple_intropattern(pat) constr(IH)
    "forall" "(" ident(x1) ident(x2) ident(x3) ident(x4) ident(x5) ident(x6) ")" :=
  iInductionRevert x "" with
    (iRevertIntros(x1 x2 x3 x4 x5 x6) "" with (iInductionCore (induction x as pat) as IH)).
Tactic Notation "iInduction" constr(x) "as" simple_intropattern(pat) constr(IH)
    "forall" "(" ident(x1) ident(x2) ident(x3) ident(x4) ident(x5) ident(x6)
    ident(x7) ")" :=
  iInductionRevert x "" with
    (iRevertIntros(x1 x2 x3 x4 x5 x6 x7) "" with (iInductionCore (induction x as pat) as IH)).
Tactic Notation "iInduction" constr(x) "as" simple_intropattern(pat) constr(IH)
    "forall" "(" ident(x1) ident(x2) ident(x3) ident(x4) ident(x5) ident(x6)
    ident(x7) ident(x8) ")" :=
  iInductionRevert x "" with
    (iRevertIntros(x1 x2 x3 x4 x5 x6 x7 x8) "" with (iInductionCore (induction x as pat) as IH)).

Tactic Notation "iInduction" constr(x) "as" simple_intropattern(pat) constr(IH)
    "forall" constr(Hs) :=
  iInductionRevert x Hs with (iInductionCore (induction x as pat) as IH).
Tactic Notation "iInduction" constr(x) "as" simple_intropattern(pat) constr(IH)
    "forall" "(" ident(x1) ")" constr(Hs) :=
  iInductionRevert x Hs with
    (iRevertIntros(x1) "" with (iInductionCore (induction x as pat) as IH)).
Tactic Notation "iInduction" constr(x) "as" simple_intropattern(pat) constr(IH)
    "forall" "(" ident(x1) ident(x2) ")" constr(Hs) :=
  iInductionRevert x Hs with
    (iRevertIntros(x1 x2) "" with (iInductionCore (induction x as pat) as IH)).
Tactic Notation "iInduction" constr(x) "as" simple_intropattern(pat) constr(IH)
    "forall" "(" ident(x1) ident(x2) ident(x3) ")" constr(Hs) :=
  iInductionRevert x Hs with
    (iRevertIntros(x1 x2 x3) "" with (iInductionCore (induction x as pat) as IH)).
Tactic Notation "iInduction" constr(x) "as" simple_intropattern(pat) constr(IH)
    "forall" "(" ident(x1) ident(x2) ident(x3) ident(x4) ")" constr(Hs) :=
  iInductionRevert x Hs with
    (iRevertIntros(x1 x2 x3 x4) "" with (iInductionCore (induction x as pat) as IH)).
Tactic Notation "iInduction" constr(x) "as" simple_intropattern(pat) constr(IH)
    "forall" "(" ident(x1) ident(x2) ident(x3) ident(x4) ident(x5) ")"
    constr(Hs) :=
  iInductionRevert x Hs with
    (iRevertIntros(x1 x2 x3 x4 x5) "" with (iInductionCore (induction x as pat) as IH)).
Tactic Notation "iInduction" constr(x) "as" simple_intropattern(pat) constr(IH)
    "forall" "(" ident(x1) ident(x2) ident(x3) ident(x4) ident(x5) ident(x6) ")"
    constr(Hs) :=
  iInductionRevert x Hs with
    (iRevertIntros(x1 x2 x3 x4 x5 x6) "" with (iInductionCore (induction x as pat) as IH)).
Tactic Notation "iInduction" constr(x) "as" simple_intropattern(pat) constr(IH)
    "forall" "(" ident(x1) ident(x2) ident(x3) ident(x4) ident(x5) ident(x6)
    ident(x7) ")" constr(Hs) :=
  iInductionRevert x Hs with
    (iRevertIntros(x1 x2 x3 x4 x5 x6 x7) "" with (iInductionCore (induction x as pat) as IH)).
Tactic Notation "iInduction" constr(x) "as" simple_intropattern(pat) constr(IH)
    "forall" "(" ident(x1) ident(x2) ident(x3) ident(x4) ident(x5) ident(x6)
    ident(x7) ident(x8) ")" constr(Hs) :=
  iInductionRevert x Hs with
    (iRevertIntros(x1 x2 x3 x4 x5 x6 x7 x8) "" with (iInductionCore (induction x as pat) as IH)).

Tactic Notation "iInduction" constr(x) "as" simple_intropattern(pat) constr(IH)
    "using" uconstr(u) :=
  iInductionRevert x "" with (iInductionCore (induction x as pat using u) as IH).
Tactic Notation "iInduction" constr(x) "as" simple_intropattern(pat) constr(IH)
    "using" uconstr(u) "forall" "(" ident(x1) ")" :=
  iInductionRevert x "" with (
    iRevertIntros(x1) "" with (iInductionCore (induction x as pat using u) as IH)).
Tactic Notation "iInduction" constr(x) "as" simple_intropattern(pat) constr(IH)
    "using" uconstr(u) "forall" "(" ident(x1) ident(x2) ")" :=
  iInductionRevert x "" with
    (iRevertIntros(x1 x2) "" with (iInductionCore (induction x as pat using u) as IH)).
Tactic Notation "iInduction" constr(x) "as" simple_intropattern(pat) constr(IH)
    "using" uconstr(u) "forall" "(" ident(x1) ident(x2) ident(x3) ")" :=
  iInductionRevert x "" with
    (iRevertIntros(x1 x2 x3) "" with (iInductionCore (induction x as pat using u) as IH)).
Tactic Notation "iInduction" constr(x) "as" simple_intropattern(pat) constr(IH)
    "using" uconstr(u) "forall" "(" ident(x1) ident(x2) ident(x3) ident(x4) ")" :=
  iInductionRevert x "" with
    (iRevertIntros(x1 x2 x3 x4) "" with (iInductionCore (induction x as pat using u) as IH)).
Tactic Notation "iInduction" constr(x) "as" simple_intropattern(pat) constr(IH)
    "using" uconstr(u) "forall" "(" ident(x1) ident(x2) ident(x3) ident(x4)
    ident(x5) ")" :=
  iInductionRevert x "" with
    (iRevertIntros(x1 x2 x3 x4 x5) "" with (iInductionCore (induction x as pat using u) as IH)).
Tactic Notation "iInduction" constr(x) "as" simple_intropattern(pat) constr(IH)
    "using" uconstr(u) "forall" "(" ident(x1) ident(x2) ident(x3) ident(x4)
    ident(x5) ident(x6) ")" :=
  iInductionRevert x "" with
    (iRevertIntros(x1 x2 x3 x4 x5 x6) "" with (iInductionCore (induction x as pat using u) as IH)).
Tactic Notation "iInduction" constr(x) "as" simple_intropattern(pat) constr(IH)
    "using" uconstr(u) "forall" "(" ident(x1) ident(x2) ident(x3) ident(x4)
    ident(x5) ident(x6) ident(x7) ")" :=
  iInductionRevert x "" with
    (iRevertIntros(x1 x2 x3 x4 x5 x6 x7) "" with (iInductionCore (induction x as pat using u) as IH)).
Tactic Notation "iInduction" constr(x) "as" simple_intropattern(pat) constr(IH)
    "using" uconstr(u) "forall" "(" ident(x1) ident(x2) ident(x3) ident(x4)
    ident(x5) ident(x6) ident(x7) ident(x8) ")" :=
  iInductionRevert x "" with
    (iRevertIntros(x1 x2 x3 x4 x5 x6 x7 x8) "" with (iInductionCore (induction x as pat using u) as IH)).

Tactic Notation "iInduction" constr(x) "as" simple_intropattern(pat) constr(IH)
    "using" uconstr(u) "forall" constr(Hs) :=
  iInductionRevert x Hs with (iInductionCore (induction x as pat using u) as IH).
Tactic Notation "iInduction" constr(x) "as" simple_intropattern(pat) constr(IH)
    "using" uconstr(u) "forall" "(" ident(x1) ")" constr(Hs) :=
  iInductionRevert x Hs with
    (iRevertIntros(x1) "" with (iInductionCore (induction x as pat using u) as IH)).
Tactic Notation "iInduction" constr(x) "as" simple_intropattern(pat) constr(IH)
    "using" uconstr(u) "forall" "(" ident(x1) ident(x2) ")" constr(Hs) :=
  iInductionRevert x Hs with
    (iRevertIntros(x1 x2) "" with (iInductionCore (induction x as pat using u) as IH)).
Tactic Notation "iInduction" constr(x) "as" simple_intropattern(pat) constr(IH)
    "using" uconstr(u) "forall" "(" ident(x1) ident(x2) ident(x3) ")" constr(Hs) :=
  iInductionRevert x Hs with
    (iRevertIntros(x1 x2 x3) "" with (iInductionCore (induction x as pat using u) as IH)).
Tactic Notation "iInduction" constr(x) "as" simple_intropattern(pat) constr(IH)
    "using" uconstr(u) "forall" "(" ident(x1) ident(x2) ident(x3) ident(x4) ")" constr(Hs) :=
  iInductionRevert x Hs with
    (iRevertIntros(x1 x2 x3 x4) "" with (iInductionCore (induction x as pat using u) as IH)).
Tactic Notation "iInduction" constr(x) "as" simple_intropattern(pat) constr(IH)
    "using" uconstr(u) "forall" "(" ident(x1) ident(x2) ident(x3) ident(x4)
    ident(x5) ")" constr(Hs) :=
  iInductionRevert x Hs with
    (iRevertIntros(x1 x2 x3 x4 x5) "" with (iInductionCore (induction x as pat using u) as IH)).
Tactic Notation "iInduction" constr(x) "as" simple_intropattern(pat) constr(IH)
    "using" uconstr(u) "forall" "(" ident(x1) ident(x2) ident(x3) ident(x4)
    ident(x5) ident(x6) ")" constr(Hs) :=
  iInductionRevert x Hs with
    (iRevertIntros(x1 x2 x3 x4 x5 x6) "" with (iInductionCore (induction x as pat using u) as IH)).
Tactic Notation "iInduction" constr(x) "as" simple_intropattern(pat) constr(IH)
    "using" uconstr(u) "forall" "(" ident(x1) ident(x2) ident(x3) ident(x4)
    ident(x5) ident(x6) ident(x7) ")" constr(Hs) :=
  iInductionRevert x Hs with
    (iRevertIntros(x1 x2 x3 x4 x5 x6 x7) "" with (iInductionCore (induction x as pat using u) as IH)).
Tactic Notation "iInduction" constr(x) "as" simple_intropattern(pat) constr(IH)
    "using" uconstr(u) "forall" "(" ident(x1) ident(x2) ident(x3) ident(x4)
    ident(x5) ident(x6) ident(x7) ident(x8) ")" constr(Hs) :=
  iInductionRevert x Hs with
    (iRevertIntros(x1 x2 x3 x4 x5 x6 x7 x8) "" with (iInductionCore (induction x as pat using u) as IH)).

(** * Löb Induction *)
Tactic Notation "iLöbCore" "as" constr (IH) :=
  iStartProof;
  (* apply is sometimes confused wrt. canonical structures search.
     refine should use the other unification algorithm, which should
     not have this issue. *)
  notypeclasses refine (tac_löb _ _ IH _ _ _ _);
    [reflexivity || fail "iLöb: spatial context not empty, this should not happen"
    |pm_reflexivity ||
     let IH := pretty_ident IH in
     fail "iLöb:" IH "not fresh"|].

Tactic Notation "iLöbRevert" constr(Hs) "with" tactic(tac) :=
  iRevertIntros Hs with (
    iRevertIntros "∗" with tac
  ).

Tactic Notation "iLöb" "as" constr (IH) :=
  iLöbRevert "" with (iLöbCore as IH).
Tactic Notation "iLöb" "as" constr (IH) "forall" "(" ident(x1) ")" :=
  iLöbRevert "" with (iRevertIntros(x1) "" with (iLöbCore as IH)).
Tactic Notation "iLöb" "as" constr (IH) "forall" "(" ident(x1) ident(x2) ")" :=
  iLöbRevert "" with (iRevertIntros(x1 x2) "" with (iLöbCore as IH)).
Tactic Notation "iLöb" "as" constr (IH) "forall" "(" ident(x1) ident(x2)
    ident(x3) ")" :=
  iLöbRevert "" with (iRevertIntros(x1 x2 x3) "" with (iLöbCore as IH)).
Tactic Notation "iLöb" "as" constr (IH) "forall" "(" ident(x1) ident(x2)
    ident(x3) ident(x4) ")" :=
  iLöbRevert "" with (iRevertIntros(x1 x2 x3 x4) "" with (iLöbCore as IH)).
Tactic Notation "iLöb" "as" constr (IH) "forall" "(" ident(x1) ident(x2)
    ident(x3) ident(x4) ident(x5) ")" :=
  iLöbRevert "" with (iRevertIntros(x1 x2 x3 x4 x5) "" with (iLöbCore as IH)).
Tactic Notation "iLöb" "as" constr (IH) "forall" "(" ident(x1) ident(x2)
    ident(x3) ident(x4) ident(x5) ident(x6) ")" :=
  iLöbRevert "" with (iRevertIntros(x1 x2 x3 x4 x5 x6) "" with (iLöbCore as IH)).
Tactic Notation "iLöb" "as" constr (IH) "forall" "(" ident(x1) ident(x2)
    ident(x3) ident(x4) ident(x5) ident(x6) ident(x7) ")" :=
  iLöbRevert "" with (iRevertIntros(x1 x2 x3 x4 x5 x6 x7) "" with (iLöbCore as IH)).
Tactic Notation "iLöb" "as" constr (IH) "forall" "(" ident(x1) ident(x2)
    ident(x3) ident(x4) ident(x5) ident(x6) ident(x7) ident(x8) ")" :=
  iLöbRevert "" with (iRevertIntros(x1 x2 x3 x4 x5 x6 x7 x8) "" with (iLöbCore as IH)).

Tactic Notation "iLöb" "as" constr (IH) "forall" constr(Hs) :=
  iLöbRevert Hs with (iLöbCore as IH).
Tactic Notation "iLöb" "as" constr (IH) "forall" "(" ident(x1) ")" constr(Hs) :=
  iLöbRevert Hs with (iRevertIntros(x1) "" with (iLöbCore as IH)).
Tactic Notation "iLöb" "as" constr (IH) "forall" "(" ident(x1) ident(x2) ")"
    constr(Hs) :=
  iLöbRevert Hs with (iRevertIntros(x1 x2) "" with (iLöbCore as IH)).
Tactic Notation "iLöb" "as" constr (IH) "forall" "(" ident(x1) ident(x2)
    ident(x3) ")" constr(Hs) :=
  iLöbRevert Hs with (iRevertIntros(x1 x2 x3) "" with (iLöbCore as IH)).
Tactic Notation "iLöb" "as" constr (IH) "forall" "(" ident(x1) ident(x2)
    ident(x3) ident(x4) ")" constr(Hs) :=
  iLöbRevert Hs with (iRevertIntros(x1 x2 x3 x4) "" with (iLöbCore as IH)).
Tactic Notation "iLöb" "as" constr (IH) "forall" "(" ident(x1) ident(x2)
    ident(x3) ident(x4) ident(x5) ")" constr(Hs) :=
  iLöbRevert Hs with (iRevertIntros(x1 x2 x3 x4 x5) "" with (iLöbCore as IH)).
Tactic Notation "iLöb" "as" constr (IH) "forall" "(" ident(x1) ident(x2)
    ident(x3) ident(x4) ident(x5) ident(x6) ")" constr(Hs) :=
  iLöbRevert Hs with (iRevertIntros(x1 x2 x3 x4 x5 x6) "" with (iLöbCore as IH)).
Tactic Notation "iLöb" "as" constr (IH) "forall" "(" ident(x1) ident(x2)
    ident(x3) ident(x4) ident(x5) ident(x6) ident(x7) ")" constr(Hs) :=
  iLöbRevert Hs with (iRevertIntros(x1 x2 x3 x4 x5 x6 x7) "" with (iLöbCore as IH)).
Tactic Notation "iLöb" "as" constr (IH) "forall" "(" ident(x1) ident(x2)
    ident(x3) ident(x4) ident(x5) ident(x6) ident(x7) ident(x8) ")" constr(Hs) :=
  iLöbRevert Hs with (iRevertIntros(x1 x2 x3 x4 x5 x6 x7 x8) "" with (iLöbCore as IH)).

(** * Assert *)
(* The argument [p] denotes whether [Q] is persistent. It can either be a
Boolean or an introduction pattern, which will be coerced into [true] if it
only contains `#` or `%` patterns at the top-level, and [false] otherwise. *)
Tactic Notation "iAssertCore" open_constr(Q)
    "with" constr(Hs) "as" constr(p) tactic(tac) :=
  iStartProof;
  let pats := spec_pat.parse Hs in
  lazymatch pats with
  | [_] => idtac
  | _ => fail "iAssert: exactly one specialization pattern should be given"
  end;
  let H := iFresh in
  eapply tac_assert with _ H Q;
    [pm_reflexivity
    |iSpecializeCore H with hnil pats as p; [..|tac H]].

Tactic Notation "iAssertCore" open_constr(Q) "as" constr(p) tactic(tac) :=
  let p := intro_pat_persistent p in
  lazymatch p with
  | true => iAssertCore Q with "[#]" as p tac
  | false => iAssertCore Q with "[]" as p tac
  end.

Tactic Notation "iAssert" open_constr(Q) "with" constr(Hs) "as" constr(pat) :=
  iAssertCore Q with Hs as pat (fun H => iDestructHyp H as pat).
Tactic Notation "iAssert" open_constr(Q) "with" constr(Hs) "as"
    "(" simple_intropattern(x1) ")" constr(pat) :=
  iAssertCore Q with Hs as pat (fun H => iDestructHyp H as (x1) pat).
Tactic Notation "iAssert" open_constr(Q) "with" constr(Hs) "as"
    "(" simple_intropattern(x1) simple_intropattern(x2) ")" constr(pat) :=
  iAssertCore Q with Hs as pat (fun H => iDestructHyp H as (x1 x2) pat).
Tactic Notation "iAssert" open_constr(Q) "with" constr(Hs) "as"
    "(" simple_intropattern(x1) simple_intropattern(x2) simple_intropattern(x3)
    ")" constr(pat) :=
  iAssertCore Q with Hs as pat (fun H => iDestructHyp H as (x1 x2 x3) pat).
Tactic Notation "iAssert" open_constr(Q) "with" constr(Hs) "as"
    "(" simple_intropattern(x1) simple_intropattern(x2) simple_intropattern(x3)
    simple_intropattern(x4) ")" constr(pat) :=
  iAssertCore Q with Hs as pat (fun H => iDestructHyp H as (x1 x2 x3 x4) pat).

Tactic Notation "iAssert" open_constr(Q) "as" constr(pat) :=
  iAssertCore Q as pat (fun H => iDestructHyp H as pat).
Tactic Notation "iAssert" open_constr(Q) "as"
    "(" simple_intropattern(x1) ")" constr(pat) :=
  iAssertCore Q as pat (fun H => iDestructHyp H as (x1) pat).
Tactic Notation "iAssert" open_constr(Q) "as"
    "(" simple_intropattern(x1) simple_intropattern(x2) ")" constr(pat) :=
  iAssertCore Q as pat (fun H => iDestructHyp H as (x1 x2) pat).
Tactic Notation "iAssert" open_constr(Q) "as"
    "(" simple_intropattern(x1) simple_intropattern(x2) simple_intropattern(x3)
    ")" constr(pat) :=
  iAssertCore Q as pat (fun H => iDestructHyp H as (x1 x2 x3) pat).
Tactic Notation "iAssert" open_constr(Q) "as"
    "(" simple_intropattern(x1) simple_intropattern(x2) simple_intropattern(x3)
    simple_intropattern(x4) ")" constr(pat) :=
  iAssertCore Q as pat (fun H => iDestructHyp H as (x1 x2 x3 x4) pat).

Tactic Notation "iAssert" open_constr(Q) "with" constr(Hs)
    "as" "%" simple_intropattern(pat) :=
  iAssertCore Q with Hs as true (fun H => iPure H as pat).
Tactic Notation "iAssert" open_constr(Q) "as" "%" simple_intropattern(pat) :=
  iAssert Q with "[-]" as %pat.

(** * Rewrite *)
Local Ltac iRewriteFindPred :=
  match goal with
  | |- _ ⊣⊢ ?Φ ?x =>
     generalize x;
     match goal with |- (∀ y, @?Ψ y ⊣⊢ _) => unify Φ Ψ; reflexivity end
  end.

Local Tactic Notation "iRewriteCore" constr(lr) open_constr(lem) :=
  iPoseProofCore lem as true true (fun Heq =>
    eapply (tac_rewrite _ Heq _ _ lr);
      [pm_reflexivity ||
       let Heq := pretty_ident Heq in
       fail "iRewrite:" Heq "not found"
      |iSolveTC ||
       let P := match goal with |- IntoInternalEq ?P _ _ ⊢ _ => P end in
       fail "iRewrite:" P "not an equality"
      |iRewriteFindPred
      |intros ??? ->; reflexivity|pm_prettify; iClearHyp Heq]).

Tactic Notation "iRewrite" open_constr(lem) := iRewriteCore Right lem.
Tactic Notation "iRewrite" "-" open_constr(lem) := iRewriteCore Left lem.

Local Tactic Notation "iRewriteCore" constr(lr) open_constr(lem) "in" constr(H) :=
  iPoseProofCore lem as true true (fun Heq =>
    eapply (tac_rewrite_in _ Heq _ _ H _ _ lr);
      [pm_reflexivity ||
       let Heq := pretty_ident Heq in
       fail "iRewrite:" Heq "not found"
      |pm_reflexivity ||
       let H := pretty_ident H in
       fail "iRewrite:" H "not found"
      |iSolveTC ||
       let P := match goal with |- IntoInternalEq ?P _ _ ⊢ _ => P end in
       fail "iRewrite:" P "not an equality"
      |iRewriteFindPred
      |intros ??? ->; reflexivity
      |pm_reflexivity|pm_prettify; iClearHyp Heq]).

Tactic Notation "iRewrite" open_constr(lem) "in" constr(H) :=
  iRewriteCore Right lem in H.
Tactic Notation "iRewrite" "-" open_constr(lem) "in" constr(H) :=
  iRewriteCore Left lem in H.

Ltac iSimplifyEq := repeat (
  iMatchHyp (fun H P => match P with ⌜_ = _⌝%I => iDestruct H as %? end)
  || simplify_eq/=).

(** * Update modality *)
Tactic Notation "iMod" open_constr(lem) :=
  iDestructCore lem as false (fun H => iModCore H).
Tactic Notation "iMod" open_constr(lem) "as" constr(pat) :=
  iDestructCore lem as false (fun H => iModCore H; last iDestructHyp H as pat).
Tactic Notation "iMod" open_constr(lem) "as" "(" simple_intropattern(x1) ")"
    constr(pat) :=
  iDestructCore lem as false (fun H => iModCore H; last iDestructHyp H as ( x1 ) pat).
Tactic Notation "iMod" open_constr(lem) "as" "(" simple_intropattern(x1)
    simple_intropattern(x2) ")" constr(pat) :=
  iDestructCore lem as false (fun H => iModCore H; last iDestructHyp H as ( x1 x2 ) pat).
Tactic Notation "iMod" open_constr(lem) "as" "(" simple_intropattern(x1)
    simple_intropattern(x2) simple_intropattern(x3) ")" constr(pat) :=
  iDestructCore lem as false (fun H => iModCore H; last iDestructHyp H as ( x1 x2 x3 ) pat).
Tactic Notation "iMod" open_constr(lem) "as" "(" simple_intropattern(x1)
    simple_intropattern(x2) simple_intropattern(x3) simple_intropattern(x4) ")"
    constr(pat) :=
  iDestructCore lem as false (fun H =>
    iModCore H; last iDestructHyp H as ( x1 x2 x3 x4 ) pat).
Tactic Notation "iMod" open_constr(lem) "as" "(" simple_intropattern(x1)
    simple_intropattern(x2) simple_intropattern(x3) simple_intropattern(x4)
    simple_intropattern(x5) ")" constr(pat) :=
  iDestructCore lem as false (fun H =>
    iModCore H; last iDestructHyp H as ( x1 x2 x3 x4 x5 ) pat).
Tactic Notation "iMod" open_constr(lem) "as" "(" simple_intropattern(x1)
    simple_intropattern(x2) simple_intropattern(x3) simple_intropattern(x4)
    simple_intropattern(x5) simple_intropattern(x6) ")" constr(pat) :=
  iDestructCore lem as false (fun H =>
    iModCore H; last iDestructHyp H as ( x1 x2 x3 x4 x5 x6 ) pat).
Tactic Notation "iMod" open_constr(lem) "as" "(" simple_intropattern(x1)
    simple_intropattern(x2) simple_intropattern(x3) simple_intropattern(x4)
    simple_intropattern(x5) simple_intropattern(x6) simple_intropattern(x7) ")"
    constr(pat) :=
  iDestructCore lem as false (fun H =>
    iModCore H; last iDestructHyp H as ( x1 x2 x3 x4 x5 x6 x7 ) pat).
Tactic Notation "iMod" open_constr(lem) "as" "(" simple_intropattern(x1)
    simple_intropattern(x2) simple_intropattern(x3) simple_intropattern(x4)
    simple_intropattern(x5) simple_intropattern(x6) simple_intropattern(x7)
    simple_intropattern(x8) ")" constr(pat) :=
  iDestructCore lem as false (fun H =>
    iModCore H; last iDestructHyp H as ( x1 x2 x3 x4 x5 x6 x7 x8 ) pat).

Tactic Notation "iMod" open_constr(lem) "as" "%" simple_intropattern(pat) :=
  iDestructCore lem as false (fun H => iModCore H; iPure H as pat).

(** * Invariant *)

(* Finds a hypothesis in the context that is an invariant with
   namespace [N].  To do so, we check whether for each hypothesis
   ["H":P] we can find an instance of [IntoInv P N] *)
Tactic Notation "iAssumptionInv" constr(N) :=
  let rec find Γ i :=
    lazymatch Γ with
    | Esnoc ?Γ ?j ?P' =>
      first [let H := constr:(_: IntoInv P' N) in unify i j|find Γ i]
    end in
  lazymatch goal with
  | |- envs_lookup_delete _ ?i (Envs ?Γp ?Γs _) = Some _ =>
     first [find Γp i|find Γs i]; pm_reflexivity
  end.

(* The argument [select] is the namespace [N] or hypothesis name ["H"] of the
invariant. *)
Tactic Notation "iInvCore" constr(select) "with" constr(pats) "as" open_constr(Hclose) "in" tactic(tac) :=
  iStartProof;
  let pats := spec_pat.parse pats in
  lazymatch pats with
  | [_] => idtac
  | _ => fail "iInv: exactly one specialization pattern should be given"
  end;
  let H := iFresh in
  let Pclose_pat :=
    lazymatch Hclose with
    | Some _ => open_constr:(Some _)
    | None => open_constr:(None)
    end in
  lazymatch type of select with
  | string =>
     eapply @tac_inv_elim with (i:=select) (j:=H) (Pclose:=Pclose_pat);
     first by (iAssumptionCore || fail "iInv: invariant" select "not found")
  | ident  =>
     eapply @tac_inv_elim with (i:=select) (j:=H) (Pclose:=Pclose_pat);
     first by (iAssumptionCore || fail "iInv: invariant" select "not found")
  | namespace =>
     eapply @tac_inv_elim with (j:=H) (Pclose:=Pclose_pat);
     first by (iAssumptionInv select || fail "iInv: invariant" select "not found")
  | _ => fail "iInv: selector" select "is not of the right type "
  end;
    [iSolveTC ||
     let I := match goal with |- ElimInv _ ?I  _ _ _ _ _ => I end in
     fail "iInv: cannot eliminate invariant " I
    |iSolveSideCondition
    |let R := fresh in intros R; eexists; split; [pm_reflexivity|];
     (* Now we are left proving [envs_entails Δ'' R]. *)
     iSpecializePat H pats; last (
       iApplyHyp H; clear R; pm_reduce;
       (* Now the goal is
          [∀ x, Pout x -∗ pm_option_fun Pclose x -∗? Q' x],
          reduced because we can rely on Pclose being a constructor. *)
       let x := fresh in
       iIntros (x);
       iIntro H; (* H was spatial, so it's gone due to the apply and we can reuse the name *)
       lazymatch Hclose with
       | Some ?Hcl => iIntros Hcl
       | None => idtac
       end;
       tac x H
    )].

(* Without closing view shift *)
Tactic Notation "iInvCore" constr(N) "with" constr(pats) "in" tactic(tac) :=
  iInvCore N with pats as (@None string) in ltac:(tac).
(* Without pattern *)
Tactic Notation "iInvCore" constr(N) "as" constr(Hclose) "in" tactic(tac) :=
  iInvCore N with "[$]" as Hclose in ltac:(tac).
(* Without both *)
Tactic Notation "iInvCore" constr(N) "in" tactic(tac) :=
  iInvCore N with "[$]" as (@None string) in ltac:(tac).

(* With everything *)
Tactic Notation "iInv" constr(N) "with" constr(Hs) "as" constr(pat) constr(Hclose) :=
   iInvCore N with Hs as (Some Hclose) in (fun x H => iDestructHyp H as pat).
Tactic Notation "iInv" constr(N) "with" constr(Hs) "as" "(" simple_intropattern(x1) ")"
    constr(pat) constr(Hclose) :=
   iInvCore N with Hs as (Some Hclose) in (fun x H => iDestructHyp H as (x1) pat).
Tactic Notation "iInv" constr(N) "with" constr(Hs) "as" "(" simple_intropattern(x1)
    simple_intropattern(x2) ")" constr(pat) constr(Hclose) :=
   iInvCore N with Hs as (Some Hclose) in (fun x H => iDestructHyp H as (x1 x2) pat).
Tactic Notation "iInv" constr(N) "with" constr(Hs) "as" "(" simple_intropattern(x1)
    simple_intropattern(x2) simple_intropattern(x3) ")"
    constr(pat) constr(Hclose) :=
   iInvCore N with Hs as (Some Hclose) in (fun x H => iDestructHyp H as (x1 x2 x3) pat).
Tactic Notation "iInv" constr(N) "with" constr(Hs) "as" "(" simple_intropattern(x1)
    simple_intropattern(x2) simple_intropattern(x3) simple_intropattern(x4) ")"
    constr(pat) constr(Hclose) :=
   iInvCore N with Hs as (Some Hclose) in (fun x H => iDestructHyp H as (x1 x2 x3 x4) pat).

(* Without closing view shift *)
Tactic Notation "iInv" constr(N) "with" constr(Hs) "as" constr(pat) :=
   iInvCore N with Hs in
    (fun x H => lazymatch type of x with
                | unit => destruct x as []; iDestructHyp H as pat
                | _ => fail "Missing intro pattern for accessor variable"
                end).
Tactic Notation "iInv" constr(N) "with" constr(Hs) "as" "(" simple_intropattern(x1) ")"
    constr(pat) :=
   iInvCore N with Hs in
    (fun x H => lazymatch type of x with
                | unit => destruct x as []; iDestructHyp H as (x1) pat
                | _ => revert x; intros x1; iDestructHyp H as      pat
                end).
Tactic Notation "iInv" constr(N) "with" constr(Hs) "as" "(" simple_intropattern(x1)
    simple_intropattern(x2) ")" constr(pat) :=
   iInvCore N with Hs in
    (fun x H => lazymatch type of x with
                | unit => destruct x as []; iDestructHyp H as (x1 x2) pat
                | _ => revert x; intros x1; iDestructHyp H as (   x2) pat
                end).
Tactic Notation "iInv" constr(N) "with" constr(Hs) "as" "(" simple_intropattern(x1)
    simple_intropattern(x2) simple_intropattern(x3) ")"
    constr(pat) :=
   iInvCore N with Hs in
    (fun x H => lazymatch type of x with
                | unit => destruct x as []; iDestructHyp H as (x1 x2 x3) pat
                | _ => revert x; intros x1; iDestructHyp H as (   x2 x3) pat
                end).
Tactic Notation "iInv" constr(N) "with" constr(Hs) "as" "(" simple_intropattern(x1)
    simple_intropattern(x2) simple_intropattern(x3) simple_intropattern(x4) ")"
    constr(pat) :=
   iInvCore N with Hs in
    (fun x H => lazymatch type of x with
                | unit => destruct x as []; iDestructHyp H as (x1 x2 x3 x4) pat
                | _ => revert x; intros x1; iDestructHyp H as (   x2 x3 x4) pat
                end).

(* Without pattern *)
Tactic Notation "iInv" constr(N) "as" constr(pat) constr(Hclose) :=
   iInvCore N as (Some Hclose) in
    (fun x H => lazymatch type of x with
                | unit => destruct x as []; iDestructHyp H as pat
                | _ => fail "Missing intro pattern for accessor variable"
                end).
Tactic Notation "iInv" constr(N) "as" "(" simple_intropattern(x1) ")"
    constr(pat) constr(Hclose) :=
   iInvCore N as (Some Hclose) in
    (fun x H => lazymatch type of x with
                | unit => destruct x as []; iDestructHyp H as (x1) pat
                | _ => revert x; intros x1; iDestructHyp H as      pat
                end).
Tactic Notation "iInv" constr(N) "as" "(" simple_intropattern(x1)
    simple_intropattern(x2) ")" constr(pat) constr(Hclose) :=
   iInvCore N as (Some Hclose) in
    (fun x H => lazymatch type of x with
                | unit => destruct x as []; iDestructHyp H as (x1 x2) pat
                | _ => revert x; intros x1; iDestructHyp H as (   x2) pat
                end).
Tactic Notation "iInv" constr(N) "as" "(" simple_intropattern(x1)
    simple_intropattern(x2) simple_intropattern(x3) ")"
    constr(pat) constr(Hclose) :=
   iInvCore N as (Some Hclose) in
    (fun x H => lazymatch type of x with
                | unit => destruct x as []; iDestructHyp H as (x1 x2 x3) pat
                | _ => revert x; intros x1; iDestructHyp H as (   x2 x3) pat
                end).
Tactic Notation "iInv" constr(N) "as" "(" simple_intropattern(x1)
    simple_intropattern(x2) simple_intropattern(x3) simple_intropattern(x4) ")"
    constr(pat) constr(Hclose) :=
   iInvCore N as (Some Hclose) in
    (fun x H => lazymatch type of x with
                | unit => destruct x as []; iDestructHyp H as (x1 x2 x3 x4) pat
                | _ => revert x; intros x1; iDestructHyp H as (   x2 x3 x4) pat
                end).

(* Without both *)
Tactic Notation "iInv" constr(N) "as" constr(pat) :=
   iInvCore N in
    (fun x H => lazymatch type of x with
                | unit => destruct x as []; iDestructHyp H as pat
                | _ => fail "Missing intro pattern for accessor variable"
                end).
Tactic Notation "iInv" constr(N) "as" "(" simple_intropattern(x1) ")"
    constr(pat) :=
   iInvCore N in
    (fun x H => lazymatch type of x with
                | unit => destruct x as []; iDestructHyp H as (x1) pat
                | _ => revert x; intros x1; iDestructHyp H as      pat
                end).
Tactic Notation "iInv" constr(N) "as" "(" simple_intropattern(x1)
    simple_intropattern(x2) ")" constr(pat) :=
   iInvCore N in
    (fun x H => lazymatch type of x with
                | unit => destruct x as []; iDestructHyp H as (x1 x2) pat
                | _ => revert x; intros x1; iDestructHyp H as (   x2)  pat
                end).
Tactic Notation "iInv" constr(N) "as" "(" simple_intropattern(x1)
    simple_intropattern(x2) simple_intropattern(x3) ")"
    constr(pat) :=
   iInvCore N in
    (fun x H => lazymatch type of x with
                | unit => destruct x as []; iDestructHyp H as (x1 x2 x3) pat
                | _ => revert x; intros x1; iDestructHyp H as (   x2 x3)  pat
                end).
Tactic Notation "iInv" constr(N) "as" "(" simple_intropattern(x1)
    simple_intropattern(x2) simple_intropattern(x3) simple_intropattern(x4) ")"
    constr(pat) :=
   iInvCore N in
    (fun x H => lazymatch type of x with
                | unit => destruct x as []; iDestructHyp H as (x1 x2 x3 x4) pat
                | _ => revert x; intros x1; iDestructHyp H as (   x2 x3 x4)  pat
                end).

(** Miscellaneous *)
Tactic Notation "iAccu" :=
  iStartProof; eapply tac_accu; [pm_reflexivity || fail "iAccu: not an evar"].

(** Automation *)
Hint Extern 0 (_ ⊢ _) => iStartProof.

(* Make sure that by and done solve trivial things in proof mode *)
Hint Extern 0 (envs_entails _ _) => iPureIntro; try done.
Hint Extern 0 (envs_entails _ ?Q) =>
  first [is_evar Q; fail 1|iAssumption].
Hint Extern 0 (envs_entails _ emp) => iEmpIntro.

(* TODO: look for a more principled way of adding trivial hints like those
below; see the discussion in !75 for further details. *)
Hint Extern 0 (envs_entails _ (_ ≡ _)) =>
  rewrite envs_entails_eq; apply bi.internal_eq_refl.
Hint Extern 0 (envs_entails _ (big_opL _ _ _)) =>
  rewrite envs_entails_eq; apply big_sepL_nil'.
Hint Extern 0 (envs_entails _ (big_sepL2 _ _ _)) =>
  rewrite envs_entails_eq; apply big_sepL2_nil'.
Hint Extern 0 (envs_entails _ (big_opM _ _ _)) =>
  rewrite envs_entails_eq; apply big_sepM_empty'.
Hint Extern 0 (envs_entails _ (big_opS _ _ _)) =>
  rewrite envs_entails_eq; apply big_sepS_empty'.
Hint Extern 0 (envs_entails _ (big_opMS _ _ _)) =>
  rewrite envs_entails_eq; apply big_sepMS_empty'.

(* These introduce as much as possible at once, for better performance. *)
Hint Extern 0 (envs_entails _ (∀ _, _)) => iIntros.
Hint Extern 0 (envs_entails _ (_ → _)) => iIntros.
Hint Extern 0 (envs_entails _ (_ -∗ _)) => iIntros.
(* Multi-intro doesn't work for custom binders. *)
Hint Extern 0 (envs_entails _ (∀.. _, _)) => iIntros (?).

Hint Extern 1 (envs_entails _ (_ ∧ _)) => iSplit.
Hint Extern 1 (envs_entails _ (_ ∗ _)) => iSplit.
Hint Extern 1 (envs_entails _ (▷ _)) => iNext.
Hint Extern 1 (envs_entails _ (■ _)) => iAlways.
Hint Extern 1 (envs_entails _ (<pers> _)) => iAlways.
Hint Extern 1 (envs_entails _ (<affine> _)) => iAlways.
Hint Extern 1 (envs_entails _ (□ _)) => iAlways.
Hint Extern 1 (envs_entails _ (∃ _, _)) => iExists _.
Hint Extern 1 (envs_entails _ (∃.. _, _)) => iExists _.
Hint Extern 1 (envs_entails _ (◇ _)) => iModIntro.
Hint Extern 1 (envs_entails _ (_ ∨ _)) => iLeft.
Hint Extern 1 (envs_entails _ (_ ∨ _)) => iRight.
Hint Extern 1 (envs_entails _ (|==> _)) => iModIntro.
Hint Extern 1 (envs_entails _ (<absorb> _)) => iModIntro.
Hint Extern 2 (envs_entails _ (|={_}=> _)) => iModIntro.

Hint Extern 2 (envs_entails _ (_ ∗ _)) => progress iFrame : iFrame.
