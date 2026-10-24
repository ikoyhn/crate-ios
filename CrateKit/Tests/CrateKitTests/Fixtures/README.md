These are real answers from Crate's API, made by `scripts/make_fixtures.py`: it seeds a throwaway
database and calls each endpoint through FastAPI's test client. After changing Crate's API, regenerate
them (from a Python environment with Crate's requirements, minus torch/transformers):

```bash
python scripts/make_fixtures.py ../crate "$(mktemp -d)" CrateKit/Tests/CrateKitTests/Fixtures
```
