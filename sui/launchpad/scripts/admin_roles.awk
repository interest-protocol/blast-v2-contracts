# Reads move_facts.awk records for one module and prints `module:function:role` for every
# production function that takes the blast.fun domain's AdminWitness, so the launchpad and
# migrator gates can pin one role per administrator action (ADR 0094). The role is:
#   <name>        the function asserts exactly `admin_witness.assert_role(blast_fun_domain::<name>())`
#                 as its first statement, or right after one leading generation check
#   via <callee>  the function asserts no role and hands the witness to exactly one callee
#   UNGATED       anything else: no role, several roles, or a role asserted late
# Run as: awk -F'\t' -v module=<name> -f admin_roles.awk

$1 == "FN" && $6 == 0 && index($9, "AdminWitness<BLAST_FUN_DOMAIN>") > 0 {
    body = $10
    gsub(/[ \t\n\r]+/, "", body)
    rest = body
    roles = 0
    while (match(rest, /admin_witness\.assert_role\(blast_fun_domain::[a-z_]+\(\)\);/)) {
        roles += 1
        role = substr(rest, RSTART + 44, RLENGTH - 48)
        rest = substr(rest, RSTART + RLENGTH)
    }
    if (roles == 1 \
        && body ~ /^([a-z_]+\.assert_(current|next)\(\);)?admin_witness\.assert_role\(/) {
        print module ":" $2 ":" role
    } else if (roles == 0 && gsub(/\.[a-z_]+\(admin_witness\)/, "&", body) == 1) {
        match(body, /\.[a-z_]+\(admin_witness\)/)
        print module ":" $2 ":via " substr(body, RSTART + 1, RLENGTH - 16)
    } else {
        print module ":" $2 ":UNGATED"
    }
}
