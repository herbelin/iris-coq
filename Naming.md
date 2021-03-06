# Naming conventions for variables/arguments/hypotheses in the Coq development

## small letters

* a : A = cmraT or cofeT
* b : B = cmraT or cofeT
* c
* d
* e : expr = expressions
* f = some generic function
* g = some generic function
* h : heap
* i
* j
* k
* l
* m : iGst = ghost state
* m* = prefix for option
* n
* o
* p
* q
* r : iRes = resources
* s = state (STSs)
* s = stuckness bits
* t
* u
* v : val = values of language
* w
* x
* y
* z 

## capital letters

* A : Type, cmraT or cofeT
* B : Type, cmraT or cofeT
* C
* D   
* E : coPset = Viewshift masks
* F = a functor
* G
* H = hypotheses
* I = indexing sets
* J
* K : ectx = evaluation contexts
* K = keys of a map
* L
* M = maps / global CMRA
* N : namespace
* O 
* P : uPred, iProp or Prop
* Q : uPred, iProp or Prop
* R : uPred, iProp or Prop
* S : set state = state sets in STSs
* T : set token = token sets in STSs
* U
* V : abstraction of value type in frame shift assertions
* W
* X : sets
* Y : sets
* Z : sets

## small greek letters

* γ : gname
* σ : state = state of language
* φ : interpretation of STS/Auth

## capital greek letters

* Φ : general predicate (over uPred, iProp or Prop)
* Ψ : general predicate (over uPred, iProp or Prop)

# Naming conventions for algebraic classes in the Coq development

## Suffixes

* C: OFEs
* R: cameras
* UR: unital cameras or resources algebras
* F: functors (can be combined with all of the above, e.g. CF is an OFE functor)
* G: global camera functor management
* T: canonical structurs for algebraic classes (for example ofeT for OFEs, cmraT for cameras)
