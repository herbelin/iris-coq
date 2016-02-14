(** This file is essentially a bunch of testcases. *)
From program_logic Require Import ownership.
From heap_lang Require Import substitution tactics heap notation.
Import uPred.

Section LangTests.
  Definition add := ('21 + '21)%L.
  Goal ∀ σ, prim_step add σ ('42) σ None.
  Proof. intros; do_step done. Qed.
  Definition rec_app : expr := ((rec: "f" "x" := "f" "x") '0).
  Goal ∀ σ, prim_step rec_app σ rec_app σ None.
  Proof.
    intros. rewrite /rec_app. (* FIXME: do_step does not work here *)
    by eapply (Ectx_step  _ _ _ _ _ []), (BetaS _ _ _ _ '0).
  Qed.
  Definition lam : expr := λ: "x", "x" + '21.
  Goal ∀ σ, prim_step (lam '21)%L σ add σ None.
  Proof.
    intros. rewrite /lam. (* FIXME: do_step does not work here *)
    by eapply (Ectx_step  _ _ _ _ _ []), (BetaS "" "x" ("x" + '21) _ '21).
  Qed.
End LangTests.

Section LiftingTests.
  Context {Σ : iFunctorG} (HeapI : gid) `{!HeapInG Σ HeapI}.
  Implicit Types P : iPropG heap_lang Σ.
  Implicit Types Q : val → iPropG heap_lang Σ.

  Definition e  : expr :=
    let: "x" := ref '1 in "x" <- !"x" + '1;; !"x".
  Goal ∀ γh N, heap_ctx HeapI γh N ⊑ wp N e (λ v, v = '2).
  Proof.
    move=> γh N. rewrite /e.
    rewrite -(wp_bindi (LetCtx _ _)). eapply wp_alloc; eauto; [].
    rewrite -later_intro; apply forall_intro=>l; apply wand_intro_l.
    rewrite -wp_let //= -later_intro.
    rewrite -(wp_bindi (SeqCtx (Load (Loc _)))) /=. 
    rewrite -(wp_bindi (StoreRCtx (LocV _))) /=.
    rewrite -(wp_bindi (BinOpLCtx PlusOp _)) /=.
    eapply wp_load; eauto with I; []. apply sep_mono; first done.
    rewrite -later_intro; apply wand_intro_l.
    rewrite -wp_bin_op // -later_intro.
    eapply wp_store; eauto with I; []. apply sep_mono; first done.
    rewrite -later_intro. apply wand_intro_l.
    rewrite -wp_seq -wp_value' -later_intro.
    eapply wp_load; eauto with I; []. apply sep_mono; first done.
    rewrite -later_intro. apply wand_intro_l.
    by apply const_intro.
  Qed.

  Definition FindPred : val :=
    rec: "pred" "x" "y" :=
      let: "yp" := "y" + '1 in
      if "yp" < "x" then "pred" "x" "yp" else "y".
  Definition Pred : val :=
    λ: "x",
      if "x" ≤ '0 then -FindPred (-"x" + '2) '0 else FindPred "x" '0.

  Lemma FindPred_spec n1 n2 E Q :
    (■ (n1 < n2) ∧ Q '(n2 - 1)) ⊑ wp E (FindPred 'n2 'n1) Q.
  Proof.
    revert n1; apply löb_all_1=>n1.
    rewrite (comm uPred_and (■ _)%I) assoc; apply const_elim_r=>?.
    (* first need to do the rec to get a later *)
    rewrite -(wp_bindi (AppLCtx _)) /=.
    rewrite -wp_rec // =>-/=; rewrite -wp_value //=.
    (* FIXME: ssr rewrite fails with "Error: _pattern_value_ is used in conclusion." *)
    rewrite ->(later_intro (Q _)).
    rewrite -!later_and; apply later_mono.
    (* Go on *)
    rewrite -wp_let //= -later_intro.
    rewrite -(wp_bindi (LetCtx _ _)) -wp_bin_op //= -wp_let' //= -!later_intro.
    rewrite -(wp_bindi (IfCtx _ _)) /=.
    apply wp_lt=> ?.
    - rewrite -wp_if_true -!later_intro.
      rewrite (forall_elim (n1 + 1)) const_equiv; last omega.
      by rewrite left_id impl_elim_l.
    - assert (n1 = n2 - 1) as -> by omega.
      rewrite -wp_if_false -!later_intro.
      by rewrite -wp_value // and_elim_r.
  Qed.

  Lemma Pred_spec n E Q : ▷ Q (LitV (n - 1)) ⊑ wp E (Pred 'n)%L Q.
  Proof.
    rewrite -wp_lam //=.
    rewrite -(wp_bindi (IfCtx _ _)) /=.
    apply later_mono, wp_le=> Hn.
    - rewrite -wp_if_true.
      rewrite -(wp_bindi (UnOpCtx _)) /=.
      rewrite -(wp_bind [AppLCtx _; AppRCtx _]) /=.
      rewrite -(wp_bindi (BinOpLCtx _ _)) /=.
      rewrite -wp_un_op //=.
      rewrite -wp_bin_op //= -!later_intro.
      rewrite -FindPred_spec. apply and_intro; first by (apply const_intro; omega).
      rewrite -wp_un_op //= -later_intro.
      by assert (n - 1 = - (- n + 2 - 1)) as -> by omega.
    - rewrite -wp_if_false -!later_intro.
      rewrite -FindPred_spec.
      auto using and_intro, const_intro with omega.
  Qed.

  Goal ∀ E,
    True ⊑ wp (Σ:=globalF Σ) E (let: "x" := Pred '42 in Pred "x") (λ v, v = '40).
  Proof.
    intros E.
    rewrite -(wp_bindi (LetCtx _ _)) -Pred_spec //= -wp_let' //=.
    by rewrite -Pred_spec -!later_intro /=.
  Qed.
End LiftingTests.
