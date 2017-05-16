{-# LANGUAGE CPP, ViewPatterns #-}

module TcFlatten(
   FlattenMode(..),
   flatten, flattenManyNom,

   unflatten,
 ) where

#include "HsVersions.h"

import TcRnTypes
import TcType
import Type
import TcEvidence
import TyCon
import TyCoRep   -- performs delicate algorithm on types
import Coercion
import Var
import VarEnv
import NameEnv
import Outputable
import TcSMonad as TcS
import DynFlags( DynFlags )

import Util
import Bag
import Pair
import Control.Monad
import MonadUtils ( zipWithAndUnzipM )
import GHC.Exts ( inline )

#if __GLASGOW_HASKELL__ < 709
import Control.Applicative ( Applicative(..), (<$>) )
#endif
import Control.Arrow ( first )

{-
Note [The flattening story]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~
* A CFunEqCan is either of form
     [G] <F xis> : F xis ~ fsk   -- fsk is a FlatSkol
     [W]       x : F xis ~ fmv   -- fmv is a unification variable,
                                 -- but untouchable,
                                 -- with MetaInfo = FlatMetaTv
  where
     x is the witness variable
     fsk/fmv is a flatten skolem
     xis are function-free
  CFunEqCans are always [Wanted], or [Given], never [Derived]

  fmv untouchable just means that in a CTyVarEq, say,
       fmv ~ Int
  we do NOT unify fmv.

* KEY INSIGHTS:

   - A given flatten-skolem, fsk, is known a-priori to be equal to
     F xis (the LHS), with <F xis> evidence

   - A unification flatten-skolem, fmv, stands for the as-yet-unknown
     type to which (F xis) will eventually reduce

* Inert set invariant: if F xis1 ~ fsk1, F xis2 ~ fsk2
                       then xis1 /= xis2
  i.e. at most one CFunEqCan with a particular LHS

* Each canonical CFunEqCan x : F xis ~ fsk/fmv has its own
  distinct evidence variable x and flatten-skolem fsk/fmv.
  Why? We make a fresh fsk/fmv when the constraint is born;
  and we never rewrite the RHS of a CFunEqCan.

* Function applications can occur in the RHS of a CTyEqCan.  No reason
  not allow this, and it reduces the amount of flattening that must occur.

* Flattening a type (F xis):
    - If we are flattening in a Wanted/Derived constraint
      then create new [W] x : F xis ~ fmv
      else create new [G] x : F xis ~ fsk
      with fresh evidence variable x and flatten-skolem fsk/fmv

    - Add it to the work list

    - Replace (F xis) with fsk/fmv in the type you are flattening

    - You can also add the CFunEqCan to the "flat cache", which
      simply keeps track of all the function applications you
      have flattened.

    - If (F xis) is in the cache already, just
      use its fsk/fmv and evidence x, and emit nothing.

    - No need to substitute in the flat-cache. It's not the end
      of the world if we start with, say (F alpha ~ fmv1) and
      (F Int ~ fmv2) and then find alpha := Int.  Athat will
      simply give rise to fmv1 := fmv2 via [Interacting rule] below

* Canonicalising a CFunEqCan [G/W] x : F xis ~ fsk/fmv
    - Flatten xis (to substitute any tyvars; there are already no functions)
                  cos :: xis ~ flat_xis
    - New wanted  x2 :: F flat_xis ~ fsk/fmv
    - Add new wanted to flat cache
    - Discharge x = F cos ; x2

* Unification flatten-skolems, fmv, ONLY get unified when either
    a) The CFunEqCan takes a step, using an axiom
    b) During un-flattening
  They are never unified in any other form of equality.
  For example [W] ffmv ~ Int  is stuck; it does not unify with fmv.

* We *never* substitute in the RHS (i.e. the fsk/fmv) of a CFunEqCan.
  That would destroy the invariant about the shape of a CFunEqCan,
  and it would risk wanted/wanted interactions. The only way we
  learn information about fsk is when the CFunEqCan takes a step.

  However we *do* substitute in the LHS of a CFunEqCan (else it
  would never get to fire!)

* [Interacting rule]
    (inert)     [W] x1 : F tys ~ fmv1
    (work item) [W] x2 : F tys ~ fmv2
  Just solve one from the other:
    x2 := x1
    fmv2 := fmv1
  This just unites the two fsks into one.
  Always solve given from wanted if poss.

* For top-level reductions, see Note [Top-level reductions for type functions]
  in TcInteract


Why given-fsks, alone, doesn't work
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Could we get away with only flatten meta-tyvars, with no flatten-skolems? No.

  [W] w : alpha ~ [F alpha Int]

---> flatten
  w = ...w'...
  [W] w' : alpha ~ [fsk]
  [G] <F alpha Int> : F alpha Int ~ fsk

--> unify (no occurs check)
  alpha := [fsk]

But since fsk = F alpha Int, this is really an occurs check error.  If
that is all we know about alpha, we will succeed in constraint
solving, producing a program with an infinite type.

Even if we did finally get (g : fsk ~ Boo)l by solving (F alpha Int ~ fsk)
using axiom, zonking would not see it, so (x::alpha) sitting in the
tree will get zonked to an infinite type.  (Zonking always only does
refl stuff.)

Why flatten-meta-vars, alone doesn't work
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Look at Simple13, with unification-fmvs only

  [G] g : a ~ [F a]

---> Flatten given
  g' = g;[x]
  [G] g'  : a ~ [fmv]
  [W] x : F a ~ fmv

--> subst a in x
       x = F g' ; x2
   [W] x2 : F [fmv] ~ fmv

And now we have an evidence cycle between g' and x!

If we used a given instead (ie current story)

  [G] g : a ~ [F a]

---> Flatten given
  g' = g;[x]
  [G] g'  : a ~ [fsk]
  [G] <F a> : F a ~ fsk

---> Substitute for a
  [G] g'  : a ~ [fsk]
  [G] F (sym g'); <F a> : F [fsk] ~ fsk


Why is it right to treat fmv's differently to ordinary unification vars?
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  f :: forall a. a -> a -> Bool
  g :: F Int -> F Int -> Bool

Consider
  f (x:Int) (y:Bool)
This gives alpha~Int, alpha~Bool.  There is an inconsistency,
but really only one error.  SherLoc may tell you which location
is most likely, based on other occurrences of alpha.

Consider
  g (x:Int) (y:Bool)
Here we get (F Int ~ Int, F Int ~ Bool), which flattens to
  (fmv ~ Int, fmv ~ Bool)
But there are really TWO separate errors.

  ** We must not complain about Int~Bool. **

Moreover these two errors could arise in entirely unrelated parts of
the code.  (In the alpha case, there must be *some* connection (eg
v:alpha in common envt).)

Note [Orientation of equalities with fmvs] and
Note [Unflattening can force the solver to iterate]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Here is a bad dilemma concerning flatten meta-vars (fmvs).

This example comes from IndTypesPerfMerge, T10226, T10009.
From the ambiguity check for
  f :: (F a ~ a) => a
we get:
      [G] F a ~ a
      [W] F alpha ~ alpha, alpha ~ a

From Givens we get
      [G] F a ~ fsk, fsk ~ a

Now if we flatten we get
      [W] alpha ~ fmv, F alpha ~ fmv, alpha ~ a

Now, processing the first one first, choosing alpha := fmv
      [W] F fmv ~ fmv, fmv ~ a

And now we are stuck.  We must either *unify* fmv := a, or
use the fmv ~ a to rewrite F fmv ~ fmv, so we can make it
meet up with the given F a ~ blah.

Old solution: always put fmvs on the left, so we get
      [W] fmv ~ alpha, F alpha ~ fmv, alpha ~ a

BUT this works badly for Trac #10340:
     get :: MonadState s m => m s
     instance MonadState s (State s) where ...

     foo :: State Any Any
     foo = get

For 'foo' we instantiate 'get' at types mm ss
       [W] MonadState ss mm, [W] mm ss ~ State Any Any
Flatten, and decompose
       [W] MonadState ss mm, [W] Any ~ fmv, [W] mm ~ State fmv, [W] fmv ~ ss
Unify mm := State fmv:
       [W] MonadState ss (State fmv), [W] Any ~ fmv, [W] fmv ~ ss
If we orient with (untouchable) fmv on the left we are now stuck:
alas, the instance does not match!!  But if instead we orient with
(touchable) ss on the left, we unify ss:=fmv, to get
       [W] MonadState fmv (State fmv), [W] Any ~ fmv
Now we can solve.

This is a real dilemma. CURRENT SOLUTION:
 * Orient with touchable variables on the left.  This is the
   simple, uniform thing to do.  So we would orient ss ~ fmv,
   not the other way round.

 * In the 'f' example, we get stuck with
        F fmv ~ fmv, fmv ~ a
   But during unflattening we will fail to dischargeFmv for the
   CFunEqCan F fmv ~ fmv, because fmv := F fmv would make an ininite
   type.  Instead we unify fmv:=a, AND record that we have done so.

   If any such "non-CFunEqCan unifications" take place (in
   unflatten_eq in TcFlatten.unflatten) iterate the entire process.
   This is done by the 'go' loop in solveSimpleWanteds.

This story does not feel right but it's the best I can do; and the
iteration only happens in pretty obscure circumstances.


************************************************************************
*                                                                      *
*                  Other notes (Oct 14)
      I have not revisted these, but I didn't want to discard them
*                                                                      *
************************************************************************


Try: rewrite wanted with wanted only for fmvs (not all meta-tyvars)

But:   fmv ~ alpha[0]
       alpha[0] ~ fmv’
Now we don’t see that fmv ~ fmv’, which is a problem for injectivity detection.

Conclusion: rewrite wanteds with wanted for all untouchables.

skol ~ untch, must re-orieint to untch ~ skol, so that we can use it to rewrite.



************************************************************************
*                                                                      *
*                  Examples
     Here is a long series of examples I had to work through
*                                                                      *
************************************************************************

Simple20
~~~~~~~~
axiom F [a] = [F a]

 [G] F [a] ~ a
-->
 [G] fsk ~ a
 [G] [F a] ~ fsk  (nc)
-->
 [G] F a ~ fsk2
 [G] fsk ~ [fsk2]
 [G] fsk ~ a
-->
 [G] F a ~ fsk2
 [G] a ~ [fsk2]
 [G] fsk ~ a


-----------------------------------

----------------------------------------
indexed-types/should_compile/T44984

  [W] H (F Bool) ~ H alpha
  [W] alpha ~ F Bool
-->
  F Bool  ~ fmv0
  H fmv0  ~ fmv1
  H alpha ~ fmv2

  fmv1 ~ fmv2
  fmv0 ~ alpha

flatten
~~~~~~~
  fmv0  := F Bool
  fmv1  := H (F Bool)
  fmv2  := H alpha
  alpha := F Bool
plus
  fmv1 ~ fmv2

But these two are equal under the above assumptions.
Solve by Refl.


--- under plan B, namely solve fmv1:=fmv2 eagerly ---
  [W] H (F Bool) ~ H alpha
  [W] alpha ~ F Bool
-->
  F Bool  ~ fmv0
  H fmv0  ~ fmv1
  H alpha ~ fmv2

  fmv1 ~ fmv2
  fmv0 ~ alpha
-->
  F Bool  ~ fmv0
  H fmv0  ~ fmv1
  H alpha ~ fmv2    fmv2 := fmv1

  fmv0 ~ alpha

flatten
  fmv0 := F Bool
  fmv1 := H fmv0 = H (F Bool)
  retain   H alpha ~ fmv2
    because fmv2 has been filled
  alpha := F Bool


----------------------------
indexed-types/should_failt/T4179

after solving
  [W] fmv_1 ~ fmv_2
  [W] A3 (FCon x)           ~ fmv_1    (CFunEqCan)
  [W] A3 (x (aoa -> fmv_2)) ~ fmv_2    (CFunEqCan)

----------------------------------------
indexed-types/should_fail/T7729a

a)  [W]   BasePrimMonad (Rand m) ~ m1
b)  [W]   tt m1 ~ BasePrimMonad (Rand m)

--->  process (b) first
    BasePrimMonad (Ramd m) ~ fmv_atH
    fmv_atH ~ tt m1

--->  now process (a)
    m1 ~ s_atH ~ tt m1    -- An obscure occurs check


----------------------------------------
typecheck/TcTypeNatSimple

Original constraint
  [W] x + y ~ x + alpha  (non-canonical)
==>
  [W] x + y     ~ fmv1   (CFunEqCan)
  [W] x + alpha ~ fmv2   (CFuneqCan)
  [W] fmv1 ~ fmv2        (CTyEqCan)

(sigh)

----------------------------------------
indexed-types/should_fail/GADTwrong1

  [G] Const a ~ ()
==> flatten
  [G] fsk ~ ()
  work item: Const a ~ fsk
==> fire top rule
  [G] fsk ~ ()
  work item fsk ~ ()

Surely the work item should rewrite to () ~ ()?  Well, maybe not;
it'a very special case.  More generally, our givens look like
F a ~ Int, where (F a) is not reducible.


----------------------------------------
indexed_types/should_fail/T8227:

Why using a different can-rewrite rule in CFunEqCan heads
does not work.

Assuming NOT rewriting wanteds with wanteds

   Inert: [W] fsk_aBh ~ fmv_aBk -> fmv_aBk
          [W] fmv_aBk ~ fsk_aBh

          [G] Scalar fsk_aBg ~ fsk_aBh
          [G] V a ~ f_aBg

   Worklist includes  [W] Scalar fmv_aBi ~ fmv_aBk
   fmv_aBi, fmv_aBk are flatten unificaiton variables

   Work item: [W] V fsk_aBh ~ fmv_aBi

Note that the inert wanteds are cyclic, because we do not rewrite
wanteds with wanteds.


Then we go into a loop when normalise the work-item, because we
use rewriteOrSame on the argument of V.

Conclusion: Don't make canRewrite context specific; instead use
[W] a ~ ty to rewrite a wanted iff 'a' is a unification variable.


----------------------------------------

Here is a somewhat similar case:

   type family G a :: *

   blah :: (G a ~ Bool, Eq (G a)) => a -> a
   blah = error "urk"

   foo x = blah x

For foo we get
   [W] Eq (G a), G a ~ Bool
Flattening
   [W] G a ~ fmv, Eq fmv, fmv ~ Bool
We can't simplify away the Eq Bool unless we substitute for fmv.
Maybe that doesn't matter: we would still be left with unsolved
G a ~ Bool.

--------------------------
Trac #9318 has a very simple program leading to

  [W] F Int ~ Int
  [W] F Int ~ Bool

We don't want to get "Error Int~Bool".  But if fmv's can rewrite
wanteds, we will

  [W] fmv ~ Int
  [W] fmv ~ Bool
--->
  [W] Int ~ Bool


************************************************************************
*                                                                      *
*                FlattenEnv & FlatM
*             The flattening environment & monad
*                                                                      *
************************************************************************

-}

type FlatWorkListRef = TcRef [Ct]  -- See Note [The flattening work list]

data FlattenEnv
  = FE { fe_mode    :: FlattenMode
       , fe_loc     :: CtLoc              -- See Note [Flattener CtLoc]
       , fe_flavour :: CtFlavour
       , fe_eq_rel  :: EqRel              -- See Note [Flattener EqRels]
       , fe_work    :: FlatWorkListRef }  -- See Note [The flattening work list]

data FlattenMode  -- Postcondition for all three: inert wrt the type substitution
  = FM_FlattenAll          -- Postcondition: function-free
  | FM_SubstOnly           -- See Note [Flattening under a forall]

--  | FM_Avoid TcTyVar Bool  -- See Note [Lazy flattening]
--                           -- Postcondition:
--                           --  * tyvar is only mentioned in result under a rigid path
--                           --    e.g.   [a] is ok, but F a won't happen
--                           --  * If flat_top is True, top level is not a function application
--                           --   (but under type constructors is ok e.g. [F a])

mkFlattenEnv :: FlattenMode -> CtEvidence -> FlatWorkListRef -> FlattenEnv
mkFlattenEnv fm ctev ref = FE { fe_mode    = fm
                              , fe_loc     = ctEvLoc ctev
                              , fe_flavour = ctEvFlavour ctev
                              , fe_eq_rel  = ctEvEqRel ctev
                              , fe_work    = ref }

-- | The 'FlatM' monad is a wrapper around 'TcS' with the following
-- extra capabilities: (1) it offers access to a 'FlattenEnv';
-- and (2) it maintains the flattening worklist.
-- See Note [The flattening work list].
newtype FlatM a
  = FlatM { runFlatM :: FlattenEnv -> TcS a }

instance Monad FlatM where
  return = pure
  m >>= k  = FlatM $ \env ->
             do { a  <- runFlatM m env
                ; runFlatM (k a) env }

instance Functor FlatM where
  fmap = liftM

instance Applicative FlatM where
  pure x = FlatM $ const (pure x)
  (<*>) = ap

liftTcS :: TcS a -> FlatM a
liftTcS thing_inside
  = FlatM $ const thing_inside

emitFlatWork :: Ct -> FlatM ()
-- See Note [The flattening work list]
emitFlatWork ct = FlatM $ \env -> updTcRef (fe_work env) (ct :)

runFlatten :: FlattenMode -> CtEvidence -> FlatM a -> TcS a
-- Run thing_inside (which does flattening), and put all
-- the work it generates onto the main work list
-- See Note [The flattening work list]
-- NB: The returned evidence is always the same as the original, but with
-- perhaps a new CtLoc
runFlatten mode ev thing_inside
  = do { flat_ref <- newTcRef []
       ; let fmode = mkFlattenEnv mode ev flat_ref
       ; res <- runFlatM thing_inside fmode
       ; new_flats <- readTcRef flat_ref
       ; updWorkListTcS (add_flats new_flats)
       ; return res }
  where
    add_flats new_flats wl
      = wl { wl_funeqs = add_funeqs new_flats (wl_funeqs wl) }

    add_funeqs []     wl = wl
    add_funeqs (f:fs) wl = add_funeqs fs (f:wl)
      -- add_funeqs fs ws = reverse fs ++ ws
      -- e.g. add_funeqs [f1,f2,f3] [w1,w2,w3,w4]
      --        = [f3,f2,f1,w1,w2,w3,w4]

traceFlat :: String -> SDoc -> FlatM ()
traceFlat herald doc = liftTcS $ traceTcS herald doc

getFlatEnvField :: (FlattenEnv -> a) -> FlatM a
getFlatEnvField accessor
  = FlatM $ \env -> return (accessor env)

getEqRel :: FlatM EqRel
getEqRel = getFlatEnvField fe_eq_rel

getRole :: FlatM Role
getRole = eqRelRole <$> getEqRel

getFlavour :: FlatM CtFlavour
getFlavour = getFlatEnvField fe_flavour

getFlavourRole :: FlatM CtFlavourRole
getFlavourRole
  = do { flavour <- getFlavour
       ; eq_rel <- getEqRel
       ; return (flavour, eq_rel) }

getMode :: FlatM FlattenMode
getMode = getFlatEnvField fe_mode

getLoc :: FlatM CtLoc
getLoc = getFlatEnvField fe_loc

checkStackDepth :: Type -> FlatM ()
checkStackDepth ty
  = do { loc <- getLoc
       ; liftTcS $ checkReductionDepth loc ty }

-- | Change the 'EqRel' in a 'FlatM'.
setEqRel :: EqRel -> FlatM a -> FlatM a
setEqRel new_eq_rel thing_inside
  = FlatM $ \env ->
    if new_eq_rel == fe_eq_rel env
    then runFlatM thing_inside env
    else runFlatM thing_inside (env { fe_eq_rel = new_eq_rel })

-- | Change the 'FlattenMode' in a 'FlattenEnv'.
setMode :: FlattenMode -> FlatM a -> FlatM a
setMode new_mode thing_inside
  = FlatM $ \env ->
    if new_mode `eq` fe_mode env
    then runFlatM thing_inside env
    else runFlatM thing_inside (env { fe_mode = new_mode })
  where
    FM_FlattenAll   `eq` FM_FlattenAll   = True
    FM_SubstOnly    `eq` FM_SubstOnly    = True
--  FM_Avoid tv1 b1 `eq` FM_Avoid tv2 b2 = tv1 == tv2 && b1 == b2
    _               `eq` _               = False

-- | Use when flattening kinds/kind coercions. See
-- Note [No derived kind equalities] in TcCanonical
flattenKinds :: FlatM a -> FlatM a
flattenKinds thing_inside
  = FlatM $ \env ->
    let kind_flav = case fe_flavour env of
                      Given -> Given
                      _     -> Wanted
    in
    runFlatM thing_inside (env { fe_eq_rel = NomEq, fe_flavour = kind_flav })

bumpDepth :: FlatM a -> FlatM a
bumpDepth (FlatM thing_inside)
  = FlatM $ \env -> do { let env' = env { fe_loc = bumpCtLocDepth (fe_loc env) }
                       ; thing_inside env' }

-- Flatten skolems
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
newFlattenSkolemFlatM :: TcType         -- F xis
                      -> FlatM (CtEvidence, Coercion, TcTyVar) -- [W] x:: F xis ~ fsk
newFlattenSkolemFlatM ty
  = do { flavour <- getFlavour
       ; loc <- getLoc
       ; liftTcS $ newFlattenSkolem flavour loc ty }

{-
Note [The flattening work list]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The "flattening work list", held in the fe_work field of FlattenEnv,
is a list of CFunEqCans generated during flattening.  The key idea
is this.  Consider flattening (Eq (F (G Int) (H Bool)):
  * The flattener recursively calls itself on sub-terms before building
    the main term, so it will encounter the terms in order
              G Int
              H Bool
              F (G Int) (H Bool)
    flattening to sub-goals
              w1: G Int ~ fuv0
              w2: H Bool ~ fuv1
              w3: F fuv0 fuv1 ~ fuv2

  * Processing w3 first is BAD, because we can't reduce i t,so it'll
    get put into the inert set, and later kicked out when w1, w2 are
    solved.  In Trac #9872 this led to inert sets containing hundreds
    of suspended calls.

  * So we want to process w1, w2 first.

  * So you might think that we should just use a FIFO deque for the work-list,
    so that putting adding goals in order w1,w2,w3 would mean we processed
    w1 first.

  * BUT suppose we have 'type instance G Int = H Char'.  Then processing
    w1 leads to a new goal
                w4: H Char ~ fuv0
    We do NOT want to put that on the far end of a deque!  Instead we want
    to put it at the *front* of the work-list so that we continue to work
    on it.

So the work-list structure is this:

  * The wl_funeqs (in TcS) is a LIFO stack; we push new goals (such as w4) on
    top (extendWorkListFunEq), and take new work from the top
    (selectWorkItem).

  * When flattening, emitFlatWork pushes new flattening goals (like
    w1,w2,w3) onto the flattening work list, fe_work, another
    push-down stack.

  * When we finish flattening, we *reverse* the fe_work stack
    onto the wl_funeqs stack (which brings w1 to the top).

The function runFlatten initialises the fe_work stack, and reverses
it onto wl_fun_eqs at the end.

Note [Flattener EqRels]
~~~~~~~~~~~~~~~~~~~~~~~
When flattening, we need to know which equality relation -- nominal
or representation -- we should be respecting. The only difference is
that we rewrite variables by representational equalities when fe_eq_rel
is ReprEq, and that we unwrap newtypes when flattening w.r.t.
representational equality.

Note [Flattener CtLoc]
~~~~~~~~~~~~~~~~~~~~~~
The flattener does eager type-family reduction.
Type families might loop, and we
don't want GHC to do so. A natural solution is to have a bounded depth
to these processes. A central difficulty is that such a solution isn't
quite compositional. For example, say it takes F Int 10 steps to get to Bool.
How many steps does it take to get from F Int -> F Int to Bool -> Bool?
10? 20? What about getting from Const Char (F Int) to Char? 11? 1? Hard to
know and hard to track. So, we punt, essentially. We store a CtLoc in
the FlattenEnv and just update the environment when recurring. In the
TyConApp case, where there may be multiple type families to flatten,
we just copy the current CtLoc into each branch. If any branch hits the
stack limit, then the whole thing fails.

A consequence of this is that setting the stack limits appropriately
will be essentially impossible. So, the official recommendation if a
stack limit is hit is to disable the check entirely. Otherwise, there
will be baffling, unpredictable errors.

Note [Lazy flattening]
~~~~~~~~~~~~~~~~~~~~~~
The idea of FM_Avoid mode is to flatten less aggressively.  If we have
       a ~ [F Int]
there seems to be no great merit in lifting out (F Int).  But if it was
       a ~ [G a Int]
then we *do* want to lift it out, in case (G a Int) reduces to Bool, say,
which gets rid of the occurs-check problem.  (For the flat_top Bool, see
comments above and at call sites.)

HOWEVER, the lazy flattening actually seems to make type inference go
*slower*, not faster.  perf/compiler/T3064 is a case in point; it gets
*dramatically* worse with FM_Avoid.  I think it may be because
floating the types out means we normalise them, and that often makes
them smaller and perhaps allows more re-use of previously solved
goals.  But to be honest I'm not absolutely certain, so I am leaving
FM_Avoid in the code base.  What I'm removing is the unique place
where it is *used*, namely in TcCanonical.canEqTyVar.

See also Note [Conservative unification check] in TcUnify, which gives
other examples where lazy flattening caused problems.

Bottom line: FM_Avoid is unused for now (Nov 14).
Note: T5321Fun got faster when I disabled FM_Avoid
      T5837 did too, but it's pathalogical anyway

Note [Phantoms in the flattener]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Suppose we have

data Proxy p = Proxy

and we're flattening (Proxy ty) w.r.t. ReprEq. Then, we know that `ty`
is really irrelevant -- it will be ignored when solving for representational
equality later on. So, we omit flattening `ty` entirely. This may
violate the expectation of "xi"s for a bit, but the canonicaliser will
soon throw out the phantoms when decomposing a TyConApp. (Or, the
canonicaliser will emit an insoluble, in which case the unflattened version
yields a better error message anyway.)

-}

{- *********************************************************************
*                                                                      *
*      Externally callable flattening functions                        *
*                                                                      *
*  They are all wrapped in runFlatten, so their                        *
*  flattening work gets put into the work list                         *
*                                                                      *
********************************************************************* -}

flatten :: FlattenMode -> CtEvidence -> TcType
        -> TcS (Xi, TcCoercion)
flatten mode ev ty
  = runFlatten mode ev (flatten_one ty)

flattenManyNom :: CtEvidence -> [TcType] -> TcS ([Xi], [TcCoercion])
-- Externally-callable, hence runFlatten
-- Flatten a bunch of types all at once; in fact they are
-- always the arguments of a saturated type-family, so
--      ctEvFlavour ev = Nominal
-- and we want to flatten all at nominal role
flattenManyNom ev tys
  = runFlatten FM_FlattenAll ev (flatten_many_nom tys)

{- *********************************************************************
*                                                                      *
*           The main flattening functions
*                                                                      *
********************************************************************* -}

{- Note [Flattening]
~~~~~~~~~~~~~~~~~~~~
  flatten ty  ==>   (xi, co)
    where
      xi has no type functions, unless they appear under ForAlls
      co :: xi ~ ty

Note that it is flatten's job to flatten *every type function it sees*.
flatten is only called on *arguments* to type functions, by canEqGiven.

Flattening also:
  * zonks, removing any metavariables, and
  * applies the substitution embodied in the inert set

Because flattening zonks and the returned coercion ("co" above) is also
zonked, it's possible that (co :: xi ~ ty) isn't quite true, as ty (the
input to the flattener) might not be zonked. After zonking everything,
(co :: xi ~ ty) will be true, however. It is for this reason that we
occasionally have to explicitly zonk, when (co :: xi ~ ty) is important
even before we zonk the whole program. (In particular, this is why the
zonk in flatten_tyvar3 is necessary.)

Flattening a type also means flattening its kind. In the case of a type
variable whose kind mentions a type family, this might mean that the result
of flattening has a cast in it.

Recall that in comments we use alpha[flat = ty] to represent a
flattening skolem variable alpha which has been generated to stand in
for ty.

----- Example of flattening a constraint: ------
  flatten (List (F (G Int)))  ==>  (xi, cc)
    where
      xi  = List alpha
      cc  = { G Int ~ beta[flat = G Int],
              F beta ~ alpha[flat = F beta] }
Here
  * alpha and beta are 'flattening skolem variables'.
  * All the constraints in cc are 'given', and all their coercion terms
    are the identity.

NB: Flattening Skolems only occur in canonical constraints, which
are never zonked, so we don't need to worry about zonking doing
accidental unflattening.

Note that we prefer to leave type synonyms unexpanded when possible,
so when the flattener encounters one, it first asks whether its
transitive expansion contains any type function applications.  If so,
it expands the synonym and proceeds; if not, it simply returns the
unexpanded synonym.

Note [flatten_many performance]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
In programs with lots of type-level evaluation, flatten_many becomes
part of a tight loop. For example, see test perf/compiler/T9872a, which
calls flatten_many a whopping 7,106,808 times. It is thus important
that flatten_many be efficient.

Performance testing showed that the current implementation is indeed
efficient. It's critically important that zipWithAndUnzipM be
specialized to TcS, and it's also quite helpful to actually `inline`
it. On test T9872a, here are the allocation stats (Dec 16, 2014):

 * Unspecialized, uninlined:     8,472,613,440 bytes allocated in the heap
 * Specialized, uninlined:       6,639,253,488 bytes allocated in the heap
 * Specialized, inlined:         6,281,539,792 bytes allocated in the heap

To improve performance even further, flatten_many_nom is split off
from flatten_many, as nominal equality is the common case. This would
be natural to write using mapAndUnzipM, but even inlined, that function
is not as performant as a hand-written loop.

 * mapAndUnzipM, inlined:        7,463,047,432 bytes allocated in the heap
 * hand-written recursion:       5,848,602,848 bytes allocated in the heap

If you make any change here, pay close attention to the T9872{a,b,c} tests
and T5321Fun.

If we need to make this yet more performant, a possible way forward is to
duplicate the flattener code for the nominal case, and make that case
faster. This doesn't seem quite worth it, yet.
-}

flatten_many :: [Role] -> [Type] -> FlatM ([Xi], [Coercion])
-- Coercions :: Xi ~ Type, at roles given
-- Returns True iff (no flattening happened)
-- NB: The EvVar inside the 'fe_ev :: CtEvidence' is unused,
--     we merely want (a) Given/Solved/Derived/Wanted info
--                    (b) the GivenLoc/WantedLoc for when we create new evidence
flatten_many roles tys
-- See Note [flatten_many performance]
  = inline zipWithAndUnzipM go roles tys
  where
    go Nominal          ty = setEqRel NomEq  $ flatten_one ty
    go Representational ty = setEqRel ReprEq $ flatten_one ty
    go Phantom          ty = -- See Note [Phantoms in the flattener]
                             do { ty <- liftTcS $ zonkTcType ty
                                ; return ( ty, mkReflCo Phantom ty ) }

-- | Like 'flatten_many', but assumes that every role is nominal.
flatten_many_nom :: [Type] -> FlatM ([Xi], [Coercion])
flatten_many_nom [] = return ([], [])
-- See Note [flatten_many performance]
flatten_many_nom (ty:tys)
  = do { (xi, co) <- flatten_one ty
       ; (xis, cos) <- flatten_many_nom tys
       ; return (xi:xis, co:cos) }
------------------
flatten_one :: TcType -> FlatM (Xi, Coercion)
-- Flatten a type to get rid of type function applications, returning
-- the new type-function-free type, and a collection of new equality
-- constraints.  See Note [Flattening] for more detail.
--
-- Postcondition: Coercion :: Xi ~ TcType
-- The role on the result coercion matches the EqRel in the FlattenEnv

flatten_one xi@(LitTy {})
  = do { role <- getRole
       ; return (xi, mkReflCo role xi) }

flatten_one (TyVarTy tv)
  = do { mb_yes <- flatten_tyvar tv
       ; role <- getRole
       ; case mb_yes of
           FTRCasted tv' kco -> -- Done
                       do { traceFlat "flattenTyVar1"
                              (pprTvBndr tv' $$
                               ppr kco <+> dcolon <+> ppr (coercionKind kco))
                          ; return (ty', mkReflCo role ty
                                         `mkCoherenceLeftCo` mkSymCo kco) }
                    where
                       ty  = mkTyVarTy tv'
                       ty' = ty `mkCastTy` mkSymCo kco

           FTRFollowed ty1 co1  -- Recur
                    -> do { (ty2, co2) <- flatten_one ty1
                          ; traceFlat "flattenTyVar2" (ppr tv $$ ppr ty2)
                          ; return (ty2, co2 `mkTransCo` co1) } }

flatten_one (AppTy ty1 ty2)
  = do { (xi1,co1) <- flatten_one ty1
       ; eq_rel <- getEqRel
       ; case (eq_rel, nextRole xi1) of
           (NomEq,  _)                -> flatten_rhs xi1 co1 NomEq
           (ReprEq, Nominal)          -> flatten_rhs xi1 co1 NomEq
           (ReprEq, Representational) -> flatten_rhs xi1 co1 ReprEq
           (ReprEq, Phantom)          ->
             do { ty2 <- liftTcS $ zonkTcType ty2
                ; return ( mkAppTy xi1 ty2
                         , mkAppCo co1 (mkNomReflCo ty2)) } }
  where
    flatten_rhs xi1 co1 eq_rel2
      = do { (xi2,co2) <- setEqRel eq_rel2 $ flatten_one ty2
           ; role1 <- getRole
           ; let role2 = eqRelRole eq_rel2
           ; traceFlat "flatten/appty"
                       (ppr ty1 $$ ppr ty2 $$ ppr xi1 $$
                        ppr xi2 $$ ppr role1 $$ ppr role2)

           ; return ( mkAppTy xi1 xi2
                    , mkTransAppCo role1 co1 xi1 ty1
                                   role2 co2 xi2 ty2
                                   role1 ) }  -- output should match fmode

flatten_one (TyConApp tc tys)
  -- Expand type synonyms that mention type families
  -- on the RHS; see Note [Flattening synonyms]
  | Just (tenv, rhs, tys') <- expandSynTyCon_maybe tc tys
  , let expanded_ty = mkAppTys (substTy (mkTvSubstPrs tenv) rhs) tys'
  = do { mode <- getMode
       ; let used_tcs = tyConsOfType rhs
       ; case mode of
           FM_FlattenAll | anyNameEnv isTypeFamilyTyCon used_tcs
                         -> flatten_one expanded_ty
           _             -> flatten_ty_con_app tc tys }

  -- Otherwise, it's a type function application, and we have to
  -- flatten it away as well, and generate a new given equality constraint
  -- between the application and a newly generated flattening skolem variable.
  | isTypeFamilyTyCon tc
  = flatten_fam_app tc tys

  -- For * a normal data type application
  --     * data family application
  -- we just recursively flatten the arguments.
  | otherwise
-- FM_Avoid stuff commented out; see Note [Lazy flattening]
--  , let fmode' = case fmode of  -- Switch off the flat_top bit in FM_Avoid
--                   FE { fe_mode = FM_Avoid tv _ }
--                     -> fmode { fe_mode = FM_Avoid tv False }
--                   _ -> fmode
  = flatten_ty_con_app tc tys

flatten_one (ForAllTy (Anon ty1) ty2)
  = do { (xi1,co1) <- flatten_one ty1
       ; (xi2,co2) <- flatten_one ty2
       ; role <- getRole
       ; return (mkFunTy xi1 xi2, mkFunCo role co1 co2) }

flatten_one ty@(ForAllTy (Named {}) _)
-- TODO (RAE): This is inadequate, as it doesn't flatten the kind of
-- the bound tyvar. Doing so will require carrying around a substitution
-- and the usual substTyVarBndr-like silliness. Argh.

-- We allow for-alls when, but only when, no type function
-- applications inside the forall involve the bound type variables.
  = do { let (bndrs, rho) = splitNamedPiTys ty
             tvs          = map (binderVar "flatten") bndrs
       ; (rho', co) <- setMode FM_SubstOnly $ flatten_one rho
                         -- Substitute only under a forall
                         -- See Note [Flattening under a forall]
       ; return (mkForAllTys bndrs rho', mkHomoForAllCos tvs co) }

flatten_one (CastTy ty g)
  = do { (xi, co) <- flatten_one ty
       ; (g', _) <- flatten_co g

       ; return (mkCastTy xi g', castCoercionKind co g' g) }

flatten_one (CoercionTy co) = first mkCoercionTy <$> flatten_co co

-- | "Flatten" a coercion. Really, just flatten the types that it coerces
-- between and then use transitivity.
flatten_co :: Coercion -> FlatM (Coercion, Coercion)
flatten_co co
  = do { let (Pair ty1 ty2, role) = coercionKindRole co
       ; co <- liftTcS $ zonkCo co  -- squeeze out any metavars from the original
       ; (co1, co2) <- flattenKinds $
                       do { (_, co1) <- flatten_one ty1
                          ; (_, co2) <- flatten_one ty2
                          ; return (co1, co2) }
       ; let co' = downgradeRole role Nominal co1 `mkTransCo`
                   co `mkTransCo`
                   mkSymCo (downgradeRole role Nominal co2)
             -- kco :: (ty1' ~r ty2') ~N (ty1 ~r ty2)
             kco = mkTyConAppCo Nominal (equalityTyCon role)
                     [ mkKindCo co1, mkKindCo co2, co1, co2 ]
       ; traceFlat "flatten_co" (vcat [ ppr co, ppr co1, ppr co2, ppr co' ])
       ; env_role <- getRole
       ; return (co', mkProofIrrelCo env_role kco co' co) }

flatten_ty_con_app :: TyCon -> [TcType] -> FlatM (Xi, Coercion)
flatten_ty_con_app tc tys
  = do { eq_rel <- getEqRel
       ; let role = eqRelRole eq_rel
       ; (xis, cos) <- case eq_rel of
                         NomEq  -> flatten_many_nom tys
                         ReprEq -> flatten_many (tyConRolesRepresentational tc) tys
       ; return (mkTyConApp tc xis, mkTyConAppCo role tc cos) }

{-
Note [Flattening synonyms]
~~~~~~~~~~~~~~~~~~~~~~~~~~
Not expanding synonyms aggressively improves error messages, and
keeps types smaller. But we need to take care.

Suppose
   type T a = a -> a
and we want to flatten the type (T (F a)).  Then we can safely flatten
the (F a) to a skolem, and return (T fsk).  We don't need to expand the
synonym.  This works because TcTyConAppCo can deal with synonyms
(unlike TyConAppCo), see Note [TcCoercions] in TcEvidence.

But (Trac #8979) for
   type T a = (F a, a)    where F is a type function
we must expand the synonym in (say) T Int, to expose the type function
to the flattener.


Note [Flattening under a forall]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Under a forall, we
  (a) MUST apply the inert substitution
  (b) MUST NOT flatten type family applications
Hence FMSubstOnly.

For (a) consider   c ~ a, a ~ T (forall b. (b, [c]))
If we don't apply the c~a substitution to the second constraint
we won't see the occurs-check error.

For (b) consider  (a ~ forall b. F a b), we don't want to flatten
to     (a ~ forall b.fsk, F a b ~ fsk)
because now the 'b' has escaped its scope.  We'd have to flatten to
       (a ~ forall b. fsk b, forall b. F a b ~ fsk b)
and we have not begun to think about how to make that work!

************************************************************************
*                                                                      *
             Flattening a type-family application
*                                                                      *
************************************************************************
-}

flatten_fam_app :: TyCon -> [TcType] -> FlatM (Xi, Coercion)
  --   flatten_fam_app            can be over-saturated
  --   flatten_exact_fam_app       is exactly saturated
  --   flatten_exact_fam_app_fully lifts out the application to top level
  -- Postcondition: Coercion :: Xi ~ F tys
flatten_fam_app tc tys  -- Can be over-saturated
    = ASSERT2( tyConArity tc <= length tys
             , ppr tc $$ ppr (tyConArity tc) $$ ppr tys)
                 -- Type functions are saturated
                 -- The type function might be *over* saturated
                 -- in which case the remaining arguments should
                 -- be dealt with by AppTys
      do { let (tys1, tys_rest) = splitAt (tyConArity tc) tys
         ; (xi1, co1) <- flatten_exact_fam_app tc tys1
               -- co1 :: xi1 ~ F tys1

               -- all Nominal roles b/c the tycon is oversaturated
         ; (xis_rest, cos_rest) <- flatten_many (repeat Nominal) tys_rest
               -- cos_res :: xis_rest ~ tys_rest

         ; return ( mkAppTys xi1 xis_rest   -- NB mkAppTys: rhs_xi might not be a type variable
                                            --    cf Trac #5655
                  , mkAppCos co1 cos_rest
                            -- (rhs_xi :: F xis) ; (F cos :: F xis ~ F tys)
                  ) }

flatten_exact_fam_app, flatten_exact_fam_app_fully ::
  TyCon -> [TcType] -> FlatM (Xi, Coercion)

flatten_exact_fam_app tc tys
  = do { mode <- getMode
       ; role <- getRole
       ; case mode of
           FM_FlattenAll -> flatten_exact_fam_app_fully tc tys

           FM_SubstOnly -> do { (xis, cos) <- flatten_many roles tys
                              ; return ( mkTyConApp tc xis
                                       , mkTyConAppCo role tc cos ) }
             where
               -- These are always going to be Nominal for now,
               -- but not if #8177 is implemented
               roles = tyConRolesX role tc }

--       FM_Avoid tv flat_top ->
--         do { (xis, cos) <- flatten_many fmode roles tys
--            ; if flat_top || tv `elemVarSet` tyCoVarsOfTypes xis
--              then flatten_exact_fam_app_fully fmode tc tys
--              else return ( mkTyConApp tc xis
--                          , mkTcTyConAppCo (feRole fmode) tc cos ) }

flatten_exact_fam_app_fully tc tys
  -- See Note [Reduce type family applications eagerly]
  = try_to_reduce tc tys False id $
    do { -- First, flatten the arguments
       ; (xis, cos) <- setEqRel NomEq $ flatten_many_nom tys
       ; eq_rel <- getEqRel
       ; let role   = eqRelRole eq_rel
             ret_co = mkTyConAppCo role tc cos
              -- ret_co :: F xis ~ F tys

        -- Now, look in the cache
       ; mb_ct <- liftTcS $ lookupFlatCache tc xis
       ; fr <- getFlavourRole
       ; case mb_ct of
           Just (co, rhs_ty, flav)  -- co :: F xis ~ fsk
             | (flav, NomEq) `funEqCanDischargeFR` fr
             ->  -- Usable hit in the flat-cache
                 -- We certainly *can* use a Wanted for a Wanted
                do { traceFlat "flatten/flat-cache hit" $ (ppr tc <+> ppr xis $$ ppr rhs_ty)
                   ; (fsk_xi, fsk_co) <- flatten_one rhs_ty
                          -- The fsk may already have been unified, so flatten it
                          -- fsk_co :: fsk_xi ~ fsk
                   ; return ( fsk_xi
                            , fsk_co `mkTransCo`
                              maybeSubCo eq_rel (mkSymCo co) `mkTransCo`
                              ret_co ) }
                                    -- :: fsk_xi ~ F xis

           -- Try to reduce the family application right now
           -- See Note [Reduce type family applications eagerly]
           _ -> try_to_reduce tc xis True (`mkTransCo` ret_co) $
                do { let fam_ty = mkTyConApp tc xis
                   ; (ev, co, fsk) <- newFlattenSkolemFlatM fam_ty
                   ; let fsk_ty = mkTyVarTy fsk
                   ; liftTcS $ extendFlatCache tc xis ( co
                                                      , fsk_ty, ctEvFlavour ev)

                   -- The new constraint (F xis ~ fsk) is not necessarily inert
                   -- (e.g. the LHS may be a redex) so we must put it in the work list
                   ; let ct = CFunEqCan { cc_ev     = ev
                                        , cc_fun    = tc
                                        , cc_tyargs = xis
                                        , cc_fsk    = fsk }
                   ; emitFlatWork ct

                   ; traceFlat "flatten/flat-cache miss" $ (ppr fam_ty $$ ppr fsk $$ ppr ev)
                   ; (fsk_xi, fsk_co) <- flatten_one fsk_ty
                   ; return (fsk_xi, fsk_co
                                     `mkTransCo`
                                     maybeSubCo eq_rel (mkSymCo co)
                                     `mkTransCo` ret_co ) }
        }

  where
    try_to_reduce :: TyCon   -- F, family tycon
                  -> [Type]  -- args, not necessarily flattened
                  -> Bool    -- add to the flat cache?
                  -> (   Coercion     -- :: xi ~ F args
                      -> Coercion )   -- what to return from outer function
                  -> FlatM (Xi, Coercion)  -- continuation upon failure
                  -> FlatM (Xi, Coercion)
    try_to_reduce tc tys cache update_co k
      = do { checkStackDepth (mkTyConApp tc tys)
           ; mb_match <- liftTcS $ matchFam tc tys
           ; case mb_match of
               Just (norm_co, norm_ty)
                 -> do { traceFlat "Eager T.F. reduction success" $
                         vcat [ ppr tc, ppr tys, ppr norm_ty
                              , ppr norm_co <+> dcolon
                                            <+> ppr (coercionKind norm_co)
                              , ppr cache]
                       ; (xi, final_co) <- bumpDepth $ flatten_one norm_ty
                       ; eq_rel <- getEqRel
                       ; let co = maybeSubCo eq_rel norm_co
                                  `mkTransCo` mkSymCo final_co
                       ; flavour <- getFlavour
                           -- NB: only extend cache with nominal equalities
                       ; when (cache && eq_rel == NomEq) $
                         liftTcS $
                         extendFlatCache tc tys ( co, xi, flavour )
                       ; return ( xi, update_co $ mkSymCo co ) }
               Nothing -> k }

{- Note [Reduce type family applications eagerly]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
If we come across a type-family application like (Append (Cons x Nil) t),
then, rather than flattening to a skolem etc, we may as well just reduce
it on the spot to (Cons x t).  This saves a lot of intermediate steps.
Examples that are helped are tests T9872, and T5321Fun.

Performance testing indicates that it's best to try this *twice*, once
before flattening arguments and once after flattening arguments.
Adding the extra reduction attempt before flattening arguments cut
the allocation amounts for the T9872{a,b,c} tests by half.

An example of where the early reduction appears helpful:

  type family Last x where
    Last '[x]     = x
    Last (h ': t) = Last t

  workitem: (x ~ Last '[1,2,3,4,5,6])

Flattening the argument never gets us anywhere, but trying to flatten
it at every step is quadratic in the length of the list. Reducing more
eagerly makes simplifying the right-hand type linear in its length.

Testing also indicated that the early reduction should *not* use the
flat-cache, but that the later reduction *should*. (Although the
effect was not large.)  Hence the Bool argument to try_to_reduce.  To
me (SLPJ) this seems odd; I get that eager reduction usually succeeds;
and if don't use the cache for eager reduction, we will miss most of
the opportunities for using it at all.  More exploration would be good
here.

At the end, once we've got a flat rhs, we extend the flatten-cache to record
the result. Doing so can save lots of work when the same redex shows up more
than once. Note that we record the link from the redex all the way to its
*final* value, not just the single step reduction. Interestingly, using the
flat-cache for the first reduction resulted in an increase in allocations
of about 3% for the four T9872x tests. However, using the flat-cache in
the later reduction is a similar gain. I (Richard E) don't currently (Dec '14)
have any knowledge as to *why* these facts are true.

************************************************************************
*                                                                      *
             Flattening a type variable
*                                                                      *
********************************************************************* -}

-- | The result of flattening a tyvar "one step".
data FlattenTvResult
  = FTRCasted TyVar Coercion
      -- ^ Flattening the tyvar's kind produced a cast.
      -- co :: new kind ~N old kind;
      -- The 'TyVar' in there might have a new, zonked kind
  | FTRFollowed TcType Coercion
      -- ^ The tyvar flattens to a not-necessarily flat other type.
      -- co :: new type ~r old type, where the role is determined by
      -- the FlattenEnv

flatten_tyvar :: TcTyVar -> FlatM FlattenTvResult
-- "Flattening" a type variable means to apply the substitution to it
-- Specifically, look up the tyvar in
--   * the internal MetaTyVar box
--   * the inerts
-- See also the documentation for FlattenTvResult

flatten_tyvar tv
  | not (isTcTyVar tv)             -- Happens when flatten under a (forall a. ty)
  = flatten_tyvar3 tv
          -- So ty contains references to the non-TcTyVar a

  | otherwise
  = do { mb_ty <- liftTcS $ isFilledMetaTyVar_maybe tv
       ; role <- getRole
       ; case mb_ty of
           Just ty -> do { traceFlat "Following filled tyvar" (ppr tv <+> equals <+> ppr ty)
                         ; return (FTRFollowed ty (mkReflCo role ty)) } ;
           Nothing -> do { fr <- getFlavourRole
                         ; flatten_tyvar2  tv fr } }

flatten_tyvar2 :: TcTyVar -> CtFlavourRole -> FlatM FlattenTvResult
-- Try in the inert equalities
-- See Definition [Applying a generalised substitution] in TcSMonad
-- See Note [Stability of flattening] in TcSMonad

flatten_tyvar2 tv fr@(flavour, eq_rel)
  | Derived <- flavour  -- For derived equalities, consult the inert_model (only)
  = do { model <- liftTcS $ getInertModel
       ; case lookupVarEnv model tv of
           Just (CTyEqCan { cc_rhs = rhs })
             -> return (FTRFollowed rhs (pprPanic "flatten_tyvar2" (ppr tv $$ ppr rhs)))
                              -- Evidence is irrelevant for Derived contexts
           _ -> flatten_tyvar3 tv }

  | otherwise   -- For non-derived equalities, consult the inert_eqs (only)
  = do { ieqs <- liftTcS $ getInertEqs
       ; case lookupVarEnv ieqs tv of
           Just (ct:_)   -- If the first doesn't work,
                         -- the subsequent ones won't either
             | CTyEqCan { cc_ev = ctev, cc_tyvar = tv, cc_rhs = rhs_ty } <- ct
             , ctEvFlavourRole ctev `eqCanRewriteFR` fr
             ->  do { traceFlat "Following inert tyvar" (ppr tv <+> equals <+> ppr rhs_ty $$ ppr ctev)
                    ; let rewrite_co1 = mkSymCo $ ctEvCoercion ctev
                          rewrite_co  = case (ctEvEqRel ctev, eq_rel) of
                            (ReprEq, _rel)  -> ASSERT( _rel == ReprEq )
                                    -- if this ASSERT fails, then
                                    -- eqCanRewriteFR answered incorrectly
                                               rewrite_co1
                            (NomEq, NomEq)  -> rewrite_co1
                            (NomEq, ReprEq) -> mkSubCo rewrite_co1

                    ; return (FTRFollowed rhs_ty rewrite_co) }
                    -- NB: ct is Derived then fmode must be also, hence
                    -- we are not going to touch the returned coercion
                    -- so ctEvCoercion is fine.

           _other -> flatten_tyvar3 tv }

flatten_tyvar3 :: TcTyVar -> FlatM FlattenTvResult
-- Always returns FTRCasted!
flatten_tyvar3 tv
  = -- Done, but make sure the kind is zonked
    do { let kind = tyVarKind tv
       ; (_new_kind, kind_co)
           <- setMode FM_SubstOnly $
              flattenKinds $
              flatten_one kind
       ; traceFlat "flattenTyVarFinal"
           (vcat [ ppr tv <+> dcolon <+> ppr (tyVarKind tv)
                 , ppr _new_kind
                 , ppr kind_co <+> dcolon <+> ppr (coercionKind kind_co) ])
       ; orig_kind <- liftTcS $ zonkTcType kind
             -- NB: orig_kind is *not* the kind returned from flatten
             -- This zonk is necessary because we might later see the tv's kind
             -- in canEqTyVarTyVar (where we use getCastedTyVar_maybe).
             -- If you remove it, then e.g. dependent/should_fail/T11407 panics
             -- See also Note [Flattening]
       ; return (FTRCasted (setTyVarKind tv orig_kind) kind_co) }

{-
Note [An alternative story for the inert substitution]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
(This entire note is just background, left here in case we ever want
 to return the the previousl state of affairs)

We used (GHC 7.8) to have this story for the inert substitution inert_eqs

 * 'a' is not in fvs(ty)
 * They are *inert* in the weaker sense that there is no infinite chain of
   (i1 `eqCanRewrite` i2), (i2 `eqCanRewrite` i3), etc

This means that flattening must be recursive, but it does allow
  [G] a ~ [b]
  [G] b ~ Maybe c

This avoids "saturating" the Givens, which can save a modest amount of work.
It is easy to implement, in TcInteract.kick_out, by only kicking out an inert
only if (a) the work item can rewrite the inert AND
        (b) the inert cannot rewrite the work item

This is signifcantly harder to think about. It can save a LOT of work
in occurs-check cases, but we don't care about them much.  Trac #5837
is an example; all the constraints here are Givens

             [G] a ~ TF (a,Int)
    -->
    work     TF (a,Int) ~ fsk
    inert    fsk ~ a

    --->
    work     fsk ~ (TF a, TF Int)
    inert    fsk ~ a

    --->
    work     a ~ (TF a, TF Int)
    inert    fsk ~ a

    ---> (attempting to flatten (TF a) so that it does not mention a
    work     TF a ~ fsk2
    inert    a ~ (fsk2, TF Int)
    inert    fsk ~ (fsk2, TF Int)

    ---> (substitute for a)
    work     TF (fsk2, TF Int) ~ fsk2
    inert    a ~ (fsk2, TF Int)
    inert    fsk ~ (fsk2, TF Int)

    ---> (top-level reduction, re-orient)
    work     fsk2 ~ (TF fsk2, TF Int)
    inert    a ~ (fsk2, TF Int)
    inert    fsk ~ (fsk2, TF Int)

    ---> (attempt to flatten (TF fsk2) to get rid of fsk2
    work     TF fsk2 ~ fsk3
    work     fsk2 ~ (fsk3, TF Int)
    inert    a   ~ (fsk2, TF Int)
    inert    fsk ~ (fsk2, TF Int)

    --->
    work     TF fsk2 ~ fsk3
    inert    fsk2 ~ (fsk3, TF Int)
    inert    a   ~ ((fsk3, TF Int), TF Int)
    inert    fsk ~ ((fsk3, TF Int), TF Int)

Because the incoming given rewrites all the inert givens, we get more and
more duplication in the inert set.  But this really only happens in pathalogical
casee, so we don't care.


************************************************************************
*                                                                      *
             Unflattening
*                                                                      *
************************************************************************

An unflattening example:
    [W] F a ~ alpha
flattens to
    [W] F a ~ fmv   (CFunEqCan)
    [W] fmv ~ alpha (CTyEqCan)
We must solve both!
-}

unflatten :: Cts -> Cts -> TcS Cts
unflatten tv_eqs funeqs
 = do { dflags   <- getDynFlags
      ; tclvl    <- getTcLevel

      ; traceTcS "Unflattening" $ braces $
        vcat [ text "Funeqs =" <+> pprCts funeqs
             , text "Tv eqs =" <+> pprCts tv_eqs ]

         -- Step 1: unflatten the CFunEqCans, except if that causes an occurs check
         -- Occurs check: consider  [W] alpha ~ [F alpha]
         --                 ==> (flatten) [W] F alpha ~ fmv, [W] alpha ~ [fmv]
         --                 ==> (unify)   [W] F [fmv] ~ fmv
         -- See Note [Unflatten using funeqs first]
      ; funeqs <- foldrBagM (unflatten_funeq dflags) emptyCts funeqs
      ; traceTcS "Unflattening 1" $ braces (pprCts funeqs)

          -- Step 2: unify the tv_eqs, if possible
      ; tv_eqs  <- foldrBagM (unflatten_eq dflags tclvl) emptyCts tv_eqs
      ; traceTcS "Unflattening 2" $ braces (pprCts tv_eqs)

          -- Step 3: fill any remaining fmvs with fresh unification variables
      ; funeqs <- mapBagM finalise_funeq funeqs
      ; traceTcS "Unflattening 3" $ braces (pprCts funeqs)

          -- Step 4: remove any tv_eqs that look like ty ~ ty
      ; tv_eqs <- foldrBagM finalise_eq emptyCts tv_eqs

      ; let all_flat = tv_eqs `andCts` funeqs
      ; traceTcS "Unflattening done" $ braces (pprCts all_flat)

          -- Step 5: zonk the result
          -- Motivation: makes them nice and ready for the next step
          --             (see TcInteract.solveSimpleWanteds)
      ; zonkSimples all_flat }
  where
    ----------------
    unflatten_funeq :: DynFlags -> Ct -> Cts -> TcS Cts
    unflatten_funeq dflags ct@(CFunEqCan { cc_fun = tc, cc_tyargs = xis
                                         , cc_fsk = fmv, cc_ev = ev }) rest
      = do {   -- fmv should be an un-filled flatten meta-tv;
               -- we now fix its final value by filling it, being careful
               -- to observe the occurs check.  Zonking will eliminate it
               -- altogether in due course
             rhs' <- zonkTcType (mkTyConApp tc xis)
           ; case occurCheckExpand dflags fmv rhs' of
               OC_OK rhs''    -- Normal case: fill the tyvar
                 -> do { setEvBindIfWanted ev
                               (EvCoercion (mkTcReflCo (ctEvRole ev) rhs''))
                       ; unflattenFmv fmv rhs''
                       ; return rest }

               _ ->  -- Occurs check
                     return (ct `consCts` rest) }

    unflatten_funeq _ other_ct _
      = pprPanic "unflatten_funeq" (ppr other_ct)

    ----------------
    finalise_funeq :: Ct -> TcS Ct
    finalise_funeq (CFunEqCan { cc_fsk = fmv, cc_ev = ev })
      = do { demoteUnfilledFmv fmv
           ; return (mkNonCanonical ev) }
    finalise_funeq ct = pprPanic "finalise_funeq" (ppr ct)

    ----------------
    unflatten_eq ::  DynFlags -> TcLevel -> Ct -> Cts -> TcS Cts
    unflatten_eq dflags tclvl ct@(CTyEqCan { cc_ev = ev, cc_tyvar = tv, cc_rhs = rhs }) rest
      | isFmvTyVar tv   -- Previously these fmvs were untouchable,
                        -- but now they are touchable
                        -- NB: unlike unflattenFmv, filling a fmv here does
                        --     bump the unification count; it is "improvement"
                        -- Note [Unflattening can force the solver to iterate]
      = do { lhs_elim <- tryFill dflags tv rhs ev
           ; if lhs_elim then return rest else
        do { rhs_elim <- try_fill dflags tclvl ev rhs (mkTyVarTy tv)
           ; if rhs_elim then return rest else
             return (ct `consCts` rest) } }

      | otherwise
      = return (ct `consCts` rest)

    unflatten_eq _ _ ct _ = pprPanic "unflatten_irred" (ppr ct)

    ----------------
    finalise_eq :: Ct -> Cts -> TcS Cts
    finalise_eq (CTyEqCan { cc_ev = ev, cc_tyvar = tv
                          , cc_rhs = rhs, cc_eq_rel = eq_rel }) rest
      | isFmvTyVar tv
      = do { ty1 <- zonkTcTyVar tv
           ; ty2 <- zonkTcType rhs
           ; let is_refl = ty1 `tcEqType` ty2
           ; if is_refl then do { setEvBindIfWanted ev
                                            (EvCoercion $
                                             mkTcReflCo (eqRelRole eq_rel) rhs)
                                ; return rest }
                        else return (mkNonCanonical ev `consCts` rest) }
      | otherwise
      = return (mkNonCanonical ev `consCts` rest)

    finalise_eq ct _ = pprPanic "finalise_irred" (ppr ct)

    ----------------
    try_fill dflags tclvl ev ty1 ty2
      | Just tv1 <- tcGetTyVar_maybe ty1
      , isTouchableOrFmv tclvl tv1
      , typeKind ty1 `eqType` tyVarKind tv1
      = tryFill dflags tv1 ty2 ev
      | otherwise
      = return False

tryFill :: DynFlags -> TcTyVar -> TcType -> CtEvidence -> TcS Bool
-- (tryFill tv rhs ev) sees if 'tv' is an un-filled MetaTv
-- If so, and if tv does not appear in 'rhs', set tv := rhs
-- bind the evidence (which should be a CtWanted) to Refl<rhs>
-- and return True.  Otherwise return False
tryFill dflags tv rhs ev
  = ASSERT2( not (isGiven ev), ppr ev )
    do { is_filled <- isFilledMetaTyVar tv
       ; if is_filled then return False else
    do { rhs' <- zonkTcType rhs
       ; case occurCheckExpand dflags tv rhs' of
           OC_OK rhs''    -- Normal case: fill the tyvar
             -> do { setEvBindIfWanted ev
                               (EvCoercion (mkTcReflCo (ctEvRole ev) rhs''))
                   ; unifyTyVar tv rhs''
                   ; return True }

           _ ->  -- Occurs check
                 return False } }

{-
Note [Unflatten using funeqs first]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    [W] G a ~ Int
    [W] F (G a) ~ G a

do not want to end up with
    [W] F Int ~ Int
because that might actually hold!  Better to end up with the two above
unsolved constraints.  The flat form will be

    G a ~ fmv1     (CFunEqCan)
    F fmv1 ~ fmv2  (CFunEqCan)
    fmv1 ~ Int     (CTyEqCan)
    fmv1 ~ fmv2    (CTyEqCan)

Flatten using the fun-eqs first.
-}
