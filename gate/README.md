# Gate — evidence collectors & offline checks

Python collectors assemble ACS scan + Trustify VEX into `evidence.json` for Conforma. Rego policies live under [`../conforma/`](../conforma/).

## Offline policy checks (no cluster)

From the repository root:

```bash
# Collector unit tests
python3 -m venv .venv && . .venv/bin/activate
pip install -r gate/requirements-dev.txt
pytest gate/tests -q

# Rego unit tests
docker run --rm -v "$PWD/conforma/policy:/policy:ro" openpolicyagent/opa:latest test /policy -v

# Conforma against fixtures
docker run --rm -v "$PWD/conforma:/conforma:ro" -w /conforma \
  quay.io/conforma/cli:latest \
  validate input testdata/evidence-pass.json --policy policy.yaml --info

docker run --rm -v "$PWD/conforma:/conforma:ro" -w /conforma \
  quay.io/conforma/cli:latest \
  validate input testdata/evidence-fail.json --policy policy.yaml --info
# → exit 1, policy.unwaived_critical for both Log4Shell CVEs
```
