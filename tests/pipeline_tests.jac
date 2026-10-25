"""End-to-end pipeline tests with a MockLLM standing in for Ollama."""

import pandas as pd;
import pandera.pandas as pa;
import from pathlib { Path }
import from jaclang.byllm.lib { MockLLM }
import from propose { ColType, ColumnRule, CsvSample, SchemaProposal, set_model }
import from profiling { TableProfile, load_csv, profile_df }
import from render { reconcile, fit_to_sample, load_schema }

glob SAMPLE: str = str(Path(__file__).resolve().parent.parent / "samples" / "people.csv");

def people_table -> TableProfile {
    return profile_df(load_csv(SAMPLE, 200));
}

def good_rules -> list[ColumnRule] {
    return [
        ColumnRule(name="id", dtype=ColType.INT, nullable=False, unique=True, min_value=1.0),
        ColumnRule(name="name", dtype=ColType.STR, nullable=False),
        ColumnRule(
            name="email",
            dtype=ColType.STR,
            nullable=False,
            regex=r"^[^@\s]+@[^@\s]+\.[a-z]+$",
        ),
        ColumnRule(name="age", dtype=ColType.INT, min_value=0.0, max_value=130.0),
        ColumnRule(name="height_m", dtype=ColType.FLOAT, min_value=0.0),
        ColumnRule(name="signup_date", dtype=ColType.DATETIME, nullable=False),
        ColumnRule(
            name="plan",
            dtype=ColType.STR,
            nullable=False,
            allowed_values=["free", "pro", "enterprise"],
        ),
        ColumnRule(name="is_active", dtype=ColType.BOOL, nullable=False),
    ];
}

"""Run the full pipeline with `rules` as the model's answer."""
def run_with(rules: list[ColumnRule], notes: list[str]) -> str {
    mock = MockLLM(outputs=[SchemaProposal(columns=rules)]);
    set_model(mock);
    table = people_table();
    sample = CsvSample(column_profile=table.to_prompt(), sample_rows=table.sample_rows());
    proposal = sample.propose_schema();
    assert "signup_date" in str(mock.seen_prompts), "profile should reach the model";
    return fit_to_sample(reconcile(proposal, table, notes), table, "people.csv", notes);
}

test "profiling guesses column types" {
    table = people_table();
    expected = {
        "id": ColType.INT,
        "name": ColType.STR,
        "age": ColType.INT,
        "height_m": ColType.FLOAT,
        "signup_date": ColType.DATETIME,
        "is_active": ColType.BOOL,
    };
    for (name, kind) in expected.items() {
        prof = table.column(name);
        assert prof is not None and prof.guessed_type == kind, f"{name}: {prof}";
    }
}

test "good proposal validates the sample unchanged" {
    notes: list[str] = [];
    code = run_with(good_rules(), notes);
    assert notes == [], str(notes);
    assert "pa.Check.isin(['free', 'pro', 'enterprise'])" in code;
    _ = load_schema(code).validate(pd.read_csv(SAMPLE), lazy=True);
}

test "rules the sample breaks are relaxed" {
    rules = good_rules();
    rules[3].max_value = 50.0;                  # ages go up to 101
    rules[3].nullable = False;                  # one age is missing
    rules[6].allowed_values = ["free", "pro"];  # misses "enterprise"
    notes: list[str] = [];
    code = run_with(rules, notes);
    joined = "\n".join(notes);
    assert "age: sample breaks max 50" in joined, joined;
    assert "age: sample has nulls" in joined, joined;
    assert "plan: sample has values outside" in joined, joined;
    assert "le(50)" not in code;
    _ = load_schema(code).validate(pd.read_csv(SAMPLE), lazy=True);
}

test "unknown columns are ignored and missing ones defaulted" {
    rules = [r for r in good_rules() if r.name != "height_m"];
    rules.append(ColumnRule(name="favourite_colour", dtype=ColType.STR));
    notes: list[str] = [];
    code = run_with(rules, notes);
    joined = "\n".join(notes);
    assert "unknown column 'favourite_colour'" in joined, joined;
    assert "height_m: model gave no rule" in joined, joined;
    assert "'height_m': pa.Column('float64'" in code;
}

test "nonsense from the model is sanitized" {
    rules = good_rules();
    rules[1].min_value = 3.0;      # bounds on a text column
    rules[2].regex = "([unclosed";  # invalid regex
    rules[7].allowed_values = ["yes"];
    notes: list[str] = [];
    code = run_with(rules, notes);
    joined = "\n".join(notes);
    assert "name: dropped min/max" in joined, joined;
    assert "email: dropped invalid regex" in joined, joined;
    assert "is_active: dropped allowed_values/regex" in joined, joined;
    _ = load_schema(code).validate(pd.read_csv(SAMPLE), lazy=True);
}

test "generated schema rejects bad data" {
    notes: list[str] = [];
    schema = load_schema(run_with(good_rules(), notes));
    bad = pd.read_csv(SAMPLE);
    bad.loc[0, "age"] = -5;
    bad.loc[1, "email"] = "not-an-email";
    bad.loc[2, "plan"] = "platinum";
    try {
        _ = schema.validate(bad, lazy=True);
        assert False, "bad data should fail validation";
    } except pa.errors.SchemaErrors as err {
        failed = set(err.failure_cases["column"].tolist());
        assert failed == {"age", "email", "plan"}, str(failed);
    }
}

test "measured types override the model's mislabels" {
    rules = good_rules();
    rules[3].dtype = ColType.STR;    # age as text
    rules[5].dtype = ColType.BOOL;   # signup_date as bool (coercion would pass!)
    rules[4].dtype = ColType.FLOAT;  # already FLOAT; INT->FLOAT widening stays allowed
    notes: list[str] = [];
    code = run_with(rules, notes);
    joined = "\n".join(notes);
    assert "age: model said STR, data is INT; kept INT" in joined, joined;
    assert "signup_date: model said BOOL, data is DATETIME" in joined, joined;
    assert "'signup_date': pa.Column('datetime64[ns]'" in code;
}

test "run_pipeline returns every stage, model rules untouched" {
    import from pipeline { run_pipeline }
    rules = good_rules();
    rules[3].max_value = 50.0;    # will be relaxed in final_rules only
    set_model(MockLLM(outputs=[SchemaProposal(columns=rules)]));
    result = run_pipeline(pd.read_csv(SAMPLE), "people.csv");
    assert result.error == "", result.error;
    assert result.model_name == "mockllm";
    assert '"max_value"' in result.model_reply, result.model_reply;
    assert result.model_rules[3].max_value == 50.0, "model_rules must stay as the model said";
    assert result.final_rules[3].max_value is None;
    assert "age: sample breaks max 50" in "\n".join(result.notes);
    _ = load_schema(result.schema_code).validate(pd.read_csv(SAMPLE), lazy=True);
}

test "run_pipeline reports model failures instead of raising" {
    import from pipeline { run_pipeline }
    import from jaclang.byllm.lib { MockError }
    set_model(MockLLM(outputs=[MockError(error=ConnectionError("ollama down"))]));
    result = run_pipeline(pd.read_csv(SAMPLE), "people.csv");
    assert result.error.startswith("Model call failed"), result.error;
    assert result.schema_code == "";
}
