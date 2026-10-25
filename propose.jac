"""The LLM step: turn a CSV profile into structured, per-column validation rules.

The model never writes code. It only fills in `ColumnRule` objects, which byLLM
parses and type-checks (retrying malformed output), so even a ~1.5B model can
produce something usable.
"""

import os;
import from jaclang.byllm.lib { Model, MockLLM }

glob DEFAULT_MODEL: str = "ollama/qwen2.5:1.5b";

# Module-level model used by `CsvSample.propose_schema`. Swap it with
# `set_model` (the CLI's --model flag, or a MockLLM in tests).
glob llm: Model | MockLLM = Model(
    model_name=os.environ.get("LLM_MODEL", DEFAULT_MODEL)
);

# A str-based enum so the model sees "INT"/"FLOAT"/... in its output schema;
# a plain enum is sent as bare integers (1, 2, 3...) and tiny models guess.
enum ColType: str {
    INT = "INT",
    FLOAT = "FLOAT",
    STR = "STR",
    BOOL = "BOOL",
    DATETIME = "DATETIME"
}

sem ColType.INT = "Whole numbers, e.g. ids, counts, ages.";
sem ColType.FLOAT = "Numbers with a fractional part, e.g. prices, measurements.";
sem ColType.STR = "Free text, names, codes, emails, categories.";
sem ColType.BOOL = "true/false values.";
sem ColType.DATETIME = "Dates or timestamps.";

obj ColumnRule {
    has name: str;
    has dtype: ColType;
    has nullable: bool = True;
    has unique: bool = False;
    has min_value: float | None = None;
    has max_value: float | None = None;
    has allowed_values: list[str] | None = None;
    has regex: str | None = None;
}

sem ColumnRule.name = "Exact column name, copied from the profile.";
sem ColumnRule.dtype = "Data type of the column. Usually the profile's guessed type.";
sem ColumnRule.nullable = "True if the column may contain missing values. Must be true if the profile shows nulls.";
sem ColumnRule.unique = "True only for identifier-like columns where every value is distinct.";
sem ColumnRule.min_value = "Smallest sensible value for INT/FLOAT columns (a domain bound such as 0), or null.";
sem ColumnRule.max_value = "Largest sensible value for INT/FLOAT columns, or null if there is no natural upper bound.";
sem ColumnRule.allowed_values = "For STR columns with only a few repeated categories: the full list of categories. Otherwise null.";
sem ColumnRule.regex = "For STR columns with an obvious pattern (emails, codes, ids): a Python regex the whole value must match. Otherwise null.";

obj SchemaProposal {
    has columns: list[ColumnRule];
}

sem SchemaProposal.columns = "One rule for every column in the profile, in the same order.";

# The CSV context lives in `has` fields and the LLM call is a zero-argument
# method: byLLM sends the object's fields as context. (In jac 0.38.2 a
# top-level `def f(x) by llm()` loses its parameter info under `jac run`.)
obj CsvSample {
    has column_profile: str;
    has sample_rows: str;

    def propose_schema -> SchemaProposal by llm(max_output_retries=3);
}

sem CsvSample = "A sample of a CSV file that needs a data validation schema.";
sem CsvSample.column_profile = "Per-column statistics computed from the CSV: guessed type, null count, unique count, min/max and example values.";
sem CsvSample.sample_rows = "The first few raw rows of the CSV, header included.";
sem CsvSample.propose_schema = "Propose a validation rule for every column so that future files shaped like this sample can be checked. Base each rule on the profile. Be conservative: only add bounds, allowed_values or a regex when the sample clearly supports them, and prefer natural domain bounds (e.g. min 0 for ages) over the exact sample min/max.";

def set_model(model: Model | MockLLM) {
    llm = model;
}
