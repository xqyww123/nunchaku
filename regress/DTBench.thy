(* Probe theory: fresh datatypes + recursive functions for the countermodel benchmark.
   Definitions only; the machine-check of the TRUE goals lives in DTBenchCheck.thy. *)
theory DTBench
  imports Main
begin

datatype 'a mtree = MLeaf | MNode "'a mtree" 'a "'a mtree"

fun mirror :: "'a mtree \<Rightarrow> 'a mtree" where
  "mirror MLeaf = MLeaf"
| "mirror (MNode l x r) = MNode (mirror r) x (mirror l)"

fun msize :: "'a mtree \<Rightarrow> nat" where
  "msize MLeaf = 0"
| "msize (MNode l x r) = msize l + msize r + 1"

fun mheight :: "'a mtree \<Rightarrow> nat" where
  "mheight MLeaf = 0"
| "mheight (MNode l x r) = max (mheight l) (mheight r) + 1"

fun mmap :: "('a \<Rightarrow> 'b) \<Rightarrow> 'a mtree \<Rightarrow> 'b mtree" where
  "mmap f MLeaf = MLeaf"
| "mmap f (MNode l x r) = MNode (mmap f l) (f x) (mmap f r)"

fun mflatten :: "'a mtree \<Rightarrow> 'a list" where
  "mflatten MLeaf = []"
| "mflatten (MNode l x r) = mflatten l @ [x] @ mflatten r"

datatype suit = Hearts | Spades | Clubs | Diamonds

fun next_suit :: "suit \<Rightarrow> suit" where
  "next_suit Hearts = Spades"
| "next_suit Spades = Clubs"
| "next_suit Clubs = Diamonds"
| "next_suit Diamonds = Hearts"

datatype pt = Pt (px: nat) (py: nat)

fun swap_pt :: "pt \<Rightarrow> pt" where
  "swap_pt (Pt a b) = Pt b a"

fun manh :: "pt \<Rightarrow> nat" where
  "manh (Pt a b) = a + b"

end
