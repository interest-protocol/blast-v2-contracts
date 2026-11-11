# Continuous fee enclosure and swap proof

## Quantity enclosed

Let $t=s/r$ be the ratio of the square-root price to the frozen reference.
The priced coordinate $x$ is $t$ for quote input and $1/t$ for asset
input. In both directions the coordinate increases along a fill. Net input
over one fixed-liquidity range is proportional to the change in $x$.
Write $b,c,k$ for the base, cap and sensitivity. Define

```text
f(t) = min(c, b + k (t² - 1)²)
h(x) = f(t) / (1 - f(t))
average = integral from x0 to x1 of h(x) dx / (x1 - x0)
```

For integer curve input $N$, a successful Move quote encloses $N$ times
this exact average in units of $2^{-96}$ input atoms. With exact curve
input $n$ before its ceiling, the exact continuous integral in input atoms
is $n$ times the average. Since $0 \le N-n < 1$ and $h \le 1/9$, the
upper endpoint also bounds the unrounded integral. Subtract $1/9$ of an
atom from the lower endpoint to bound that integral from below. The extra
input pricing is a consequence of the curve's input ceiling.

## Exact integral on an uncapped segment

Let $w=\sqrt{(1-b)/k}$, $A=1+w$, $z=1-w$, and
$g=\sqrt{(c-b)/k}$. Here $1-f(t)=k(A-t^2)(t^2-z)$. Its reciprocal is
the sum of $1/(A-t^2)$ and $1/(t^2-z)$ times $1/(2kw)$. Subtract
one from the gross density to obtain $h$.

For $t_0\le t_1$, define $p=t_0t_1$, $\delta=t_1-t_0$,
$d_1=A-p$, and $d_2=p-z$. Both denominators are positive. For each
pole, use the substitution $y=(t-t_0)/(A-t_0t)$ or
$y=(t-t_0)/(t_0t-z)$, respectively. Differentiation and factoring give
$dt/(A-t^2)=dy/(1-Ay^2)$ and $dt/(t^2-z)=dy/(1-zy^2)$.
The upper endpoints are $\delta/d_1$ and $\delta/d_2$.

For $o=1,3$, let $S_o(a)=\int_0^1 u^{o-1}/(1-au^2)\,du$. The
two averages in the upward direction are
$S_1(A\delta^2/d_1^2)/d_1$ and $S_1(z\delta^2/d_2^2)/d_2$.
For the reciprocal coordinate, the measure in increasing $t$ is
$dt/t^2$, and its total is $\delta/p$. Partial fractions give
$(1+pS_1(a_1)/d_1)/A$ and $(pS_1(a_2)/d_2-1)/z$.
Here $a_1=A\delta^2/d_1^2$ and $a_2=z\delta^2/d_2^2$.
Substituting $S_1(a)=1+aS_3(a)$ makes each expression
$1/d_i+p\delta^2 S_3(a_i)/d_i^3$. This form also holds at $z=0$
by integrating $u^2$ directly in the reciprocal coordinate.
The prefactor equals the code's $1/(2\sqrt{k(1-b)})$.

An uncapped piece has $1-g\le t_i^2\le1+g$. The reference cut puts
both endpoints on the same side of 1. The parameter bounds give
$w<16/5$ and $g/w<8/25$. Below 1, $\delta\le g$ and $p\le1$.
Above 1, $2\delta\le g$. The SMT checks show $|a_i|<0.49$
in both cases. This also bounds the true argument when the Q96
interval for $z$ straddles zero.

## Directed rounding and composition

- **Constant paths.** For a fixed fee or zero net input, direct rational
  division with floor and ceiling gives the enclosure. When the cap equals
  the base, the cap also gives the exact density for the entire path.
- **Intervals.** Use outward rounded nonnegative products and quotients.
  For absolute difference, the nearest endpoints give the minimum when
  the intervals are disjoint. The maximum is the larger of the two
  cross-endpoint distances. Newton's integer square root starts at or
  above the floor root. Every update preserves that bound. A
  nondecreasing update returns the floor root, and the final assertion
  checks it if the loop reaches its cap.
- **Series.** For $a$ with $|a|\le1/2$, apply the finite geometric
  identity to $au^2$ in $S_o$ and integrate each term. The remainder
  after term $j$ has magnitude at most
  $|a|^{j+1}/((1-|a|)(2j+2+o))$. In Q96 units, flooring successive
  powers of the midpoint loses less than two units per power.
  Dividing by $2j+o$ loses less than three units per term including
  the power error. The same absolute bound applies with alternating
  signs. The tail uses a directed upper bound on the first omitted
  power even if the rounded power reaches zero early.
- **Argument uncertainty.** The difference of the two integrands at
  $a$ and $a'$ is bounded in magnitude by
  $4|a-a'|u^{o+1}$, since both denominators are at least $1/2$.
  Its integral is at most $4|a-a'|/(o+2)$. The code's twice-width
  allowance covers midpoint uncertainty. When the pole interval crosses
  zero, twice the magnitude bound covers both possible signs around
  $S_o(0)=1/o$.
- **Cap and reference cuts.** The cap intervals bracket the cap edges.
  The lower interval ends at or before 1, and the upper interval
  starts at or after 1. Reciprocal coordinates reverse the cap edges.
  The ordered cuts partition the normalized range. A fully capped
  segment uses the constant cap. A segment near a cap edge or too short
  for the analytic branch uses endpoint bounds. Within either side of
  the reference, the squared gap, the cap operation and the fee-on-net
  transform are monotone along the segment. The analytical branch
  stays wholly inside the true uncapped range. The weighted sum uses
  each segment's length divided by the whole range's length.
- **Normalization and clamps.** The true and Q96 paths can be paired by
  the same affine interpolation parameter. Their coordinates differ
  by at most two Q96 units, including the test helper's prefix
  interpolation. In the uncapped region the derivative magnitude of
  the density is $4k|t^2-1|t/(1-f)^2$ upward and
  $4k|t^2-1|t^3/(1-f)^2$ in reciprocal coordinates. Both are below
  45. The capped parts are constant and the density is continuous, so
  the same Lipschitz bound holds across both cap edges. A 90-unit pad
  covers the coordinate error. Clamping the interval to the base and
  cap, including the exact cap after scaling by $N$, preserves the
  enclosure.

## Uniform quarter-atom guard

The [width certificate](../scripts/dex_fee_width.py) propagates exact rational
bounds in Q96 units through the pinned implementation. It applies to positive
admitted fee tiers, every in-range price and reference, and all `u64` net
inputs. A constant fee uses a direct floor and ceiling with width at most one
Q96 unit of fee. The dynamic case uses these bounds.

- The positive base and integer PPM gap put $g^2$ in
  $[10^{-8},1-10^{-5}]$. For $g\le1/2$, the radicand of the lower cap is
  at least $1/2$. For $g>1/2$, the radicand of the gap itself exceeds
  $1/4$. An interval square root amplifies the input width by
  at most the reciprocal of the sum of the two endpoint roots, plus two
  rounding units. The integer Newton seed lies between the real root and
  twice that root. Above the real root, the next relative error is at most
  half the square of the current relative error. Flooring the update can
  only reduce its positive error, while the floor-root invariant gives a
  lower bound. The normalized radicands are below $2^{200}$, so after
  eight updates the error above the real root is less than one. The next
  update or nondecreasing exit establishes the floor root within the cap.
- The analytic segment arguments are below $0.49$ in exact arithmetic and
  below $0.491$ at their outward-rounded endpoints. At index 64, the first
  omitted term uses a power bounded by $Q(0.491)^{65}$ plus the directed
  padding, where $Q=2^{96}$. An earlier exit has zero rounded power.
  Each pole denominator stays between $1/16$ and $5$. The rounded
  prefactor divided by either denominator is below one. For the reciprocal
  correction, $p\delta^2$ times the prefactor divided by the cubed
  denominator is also below one because $p\le2$ and $\delta/d\le8/17$.
  Those coupled bounds preserve the small series error. The relative
  width of the rounded cube is bounded by $48$ times the denominator
  width plus the error from the two products.
- A pointwise segment lies in a cap-edge interval or spans at most
  1,024 coordinate units. Mapping the rounded reciprocal cap edges back
  to price adds at most four units per edge. The 45-Lipschitz bound and
  the endpoint rate arithmetic bound its width. The lower weights of
  the at most six pieces sum to at most one. Consequently the width of
  their weighted average is at most the largest segment width plus
  18 units from weights and product rounding. Normalization adds 180
  more units and the final base and cap clamps only narrow the interval.

Normalized coordinates are below $2^{224}$. The three 32-bit weight shifts
fit `u256`. All other interval arithmetic uses endpoints below
$2^{17}Q$, including the reciprocal correction, whose pre-scaled series
quotients are each below $5001Q$. The final amount scaling and the
constant-fee numerator fit `u256`. Subtraction and denominator bounds
follow from the cap and pole margins, series sign pairing, and the
enclosure itself.

The resulting average width is at most **78,396,394 Q96 units**.
At $2^{64}-1$ net atoms this gives a width below **0.019 atom**,
which implies the $1/16$ atom source claim and the quarter-atom guard.

## Composition with swap execution

The enclosure bounds the upper fee error relative to the exact
rounded-input fee by the proved width. The exact accumulated integral
is monotone because its density is nonnegative. Along one constant
liquidity segment, a distinct canonical endpoint increases integer net
cost by at least one atom. The quarter-atom enclosure error and the
one-ninth-atom input-ceiling error together are less than that increase.
Thus gross input is monotone before and after the whole-atom ceiling.
The charged fee is at least the exact unrounded integral and less than
$1+1/4+1/9=49/36$ atoms above it per priced range.
Budgets that map to the same endpoint have identical charges. This
justifies the search's plateau skip and its greatest-affordable budget
invariant.

### Skipping unaffordable budgets

Let $x_i$ be the real net input to a trial endpoint, $n_i=\lceil x_i\rceil$
its canonical integer input, and $F_i$ the exact fee integral to that
endpoint. The Q96 upper fee $U_i$ satisfies $0\le U_i-F_i<13/36$ by the
input ceiling and enclosure bounds above. For two ordered endpoints,
$0\le F_2-F_1\le(x_2-x_1)/9$ because the fee per net input is at most $1/9$.
The real net difference satisfies $x_2-x_1<n_2-n_1+1$. Taking the same
whole-atom ceilings $f_i=\lceil U_i\rceil$ as `trial`, we have
$f_2\ge f_1-1$ and the gross charges $G_i=n_i+f_i$ satisfy

$$
n_2-n_1-1\;\le\;G_2-G_1\;<\;\frac{10}{9}(n_2-n_1)+2.
$$

If a trial at canonical input $n$ exceeds the budget by $e$ atoms, every
affordable earlier endpoint of canonical input $m$ must satisfy
$e\le G(n)-G(m)<10(n-m)/9+2$. Hence $m$ is at most
$n-1-\lfloor 9\max(e-2,0)/10\rfloor$. Later endpoints and the rejected
price plateau are unaffordable by monotonicity. The new upper budget
therefore retains the canonical input of every affordable endpoint.
The first affordable upper probe reaches the farthest retained endpoint.
If the upper budget falls to the initial affordable seed or below, the
seed already reaches that endpoint. Both cases return the original binary
search's price and its unchanged `trial` amounts and fee.

For a bound on work, let $t$ be the last affordable probe budget. The first
rejected budget $t+1$ is canonical by the plateau property. At a rejected
upper probe $u>t$ with canonical net $n\le u$, the lower gross-difference
bound gives $e\ge n-t-1$. The next upper budget $u'$ then satisfies
$u'-t\le\lfloor((u-t)+27)/10\rfloor$ and strictly decreases. Starting within
the `u64` domain, twenty rejections reduce the distance to at most three
atoms. At most three more rejections reach $t$ or below, where the search
either uses the seed or accepts one final probe.

The SMT runner checks the algebraic obligations behind this derivation,
the price inverses, output rounding, budget search and settlement.
The Move runner checks that the compiled rejection helper computes the
derived bound without aborting when the quote is unaffordable, its net
input fits the budget, and its fee is at most its net input. The
rejection branch supplies unaffordability, `trial` checks the net input
against its probe, and the SMT model checks the rounded fee cap.
See the [reproduction commands](README.md#swap-arithmetic-proof).

The calculus and interval composition are written here, with the local
algebraic steps checked by Z3. Sui Prover checks selected integer operations
against compiled Move. Its proof does not model real-valued integration
or Sui VM transaction semantics.

## Return conditions in compiled Move

The series check assumes an ordered Q96 argument in `[0, ONE / 2]` and an
offset of one or three. Its loop invariant bounds the power and sum and
keeps `sum * offset + offset - 1 >= power` to cover the alternating
subtraction. Sui Prover checks the loop and its tail under these conditions.
Separate contracts check coordinate normalization, constant-fee arithmetic,
and the zero-input and constant-fee quote paths. Positive input requires
distinct endpoint prices because `quote` checks that condition before
choosing the constant-fee branch.

The dynamic quote requires a compiled proof that path construction, cap
splitting, and the analytic average establish the arithmetic preconditions
at each call. The rational enclosure and width certificate supply the
mathematical bounds. The connection to these exact Move call sites remains
open.
