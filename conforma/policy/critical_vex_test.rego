package policy_test

import data.policy
import rego.v1

fail_input := {
	"apiVersion": "trust-supply-chain.poc/v1",
	"kind": "SecurityEvidence",
	"image": "quay.io/mronconi/trusted-quarkus-app:insecure",
	"scan": {
		"source": "acs",
		"critical_cves": ["CVE-2021-44228", "CVE-2021-45046"],
		"total_vulnerabilities": 255,
	},
	"vex": {
		"source": "trustify",
		"advisories": [],
		"known_not_affected": [],
	},
}

pass_input := {
	"apiVersion": "trust-supply-chain.poc/v1",
	"kind": "SecurityEvidence",
	"image": "quay.io/mronconi/trusted-quarkus-app:vex-waived",
	"scan": {
		"source": "acs",
		"critical_cves": ["CVE-2021-44228", "CVE-2021-45046"],
		"total_vulnerabilities": 255,
	},
	"vex": {
		"source": "trustify",
		"advisories": ["DEMO-VEX-QUARKUS-004"],
		"known_not_affected": ["CVE-2021-44228", "CVE-2021-45046"],
	},
}

test_deny_when_no_vex if {
	results := policy.deny with input as fail_input
	count(results) == 2
}

test_allow_when_vex_waives_all if {
	results := policy.deny with input as pass_input
	count(results) == 0
}

test_partial_waiver_still_denies if {
	partial := json.patch(fail_input, [{
		"op": "replace",
		"path": "/vex/known_not_affected",
		"value": ["CVE-2021-44228"],
	}])
	results := policy.deny with input as partial
	count(results) == 1
}
