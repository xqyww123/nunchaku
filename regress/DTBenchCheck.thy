(* Machine-check of the TRUE goals of the datatype class: this theory loading
   successfully IS the check. Kept separate from DTBench so the benchmark context
   does not contain these lemmas. *)
theory DTBenchCheck
  imports DTBench
begin

lemma d9_true: "mirror (mirror t) = t"
  by (induct t) auto

lemma d10_true: "msize (mirror t) = msize t"
  by (induct t) auto

lemma d11_true: "mheight (mirror t) = mheight t"
  by (induct t) auto

lemma d12_true: "mflatten (mmap f t) = map f (mflatten t)"
  by (induct t) auto

lemma d13_true: "next_suit s \<noteq> s"
  by (cases s) auto

lemma d14_true: "swap_pt (swap_pt p) = p"
  by (cases p) auto

lemma d15_true: "manh (swap_pt p) = manh p"
  by (cases p) auto

lemma d16_true: "msize (mmap f t) = msize t"
  by (induct t) auto

lemma b5_true: "(n::nat) < n + 100001"
  by simp

end
