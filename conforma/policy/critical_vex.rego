package policy

import rego.v1

# METADATA
# title: Unwaived CRITICAL CVEs
# description: >
#   CRITICAL CVEs reported by the ACS image scan must appear in Trustify
#   CSAF VEX as known_not_affected. Trustify is the source of truth for
#   false-positive waivers; Conforma only evaluates the evidence bundle.
# custom:
#   short_name: unwaived_critical
#   failure_msg: >-
#     CRITICAL CVE %s has no Trustify VEX known_not_affected waiver
#   solution: >
#     Upload a CSAF VEX (document.category=csaf_vex) to Trustify that lists
#     the CVE under product_status.known_not_affected, then rebuild.
#   collections:
#     - cve_vex

deny contains result if {
	some cve in unwaived_critical
	result := {
		"code": "policy.unwaived_critical",
		"msg": sprintf("CRITICAL CVE %s has no Trustify VEX known_not_affected waiver", [cve]),
		"term": cve,
	}
}

unwaived_critical contains cve if {
	some cve in input.scan.critical_cves
	not cve in input.vex.known_not_affected
}
