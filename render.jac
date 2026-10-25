"""Turn the model's rules into pandera code, then make sure the sample passes it.

Code generation is deterministic: the model only supplies rule values. The
generated source is exec'd and validated against the sample; any check the
sample itself fails is relaxed (and reported) until it passes.
"""

import re;
import pandera.pandas as pa;
import from propose { ColType, ColumnRule, SchemaProposal }
import from profiling { ColumnProfile, TableProfile }

glob MAX_RELAX_ROUNDS: int = 10;

def default_rule(prof: ColumnProfile) -> ColumnRule {
    return ColumnRule(
        name=prof.name, dtype=prof.guessed_type, nullable=prof.null_count > 0
    );
}

"""Line the model's rules up with the real columns, in CSV order."""
def reconcile(
    proposal: SchemaProposal, table: TableProfile, notes: list[str]
) -> list[ColumnRule] {
    by_name: dict[str, ColumnRule] = {r.name: r for r in proposal.columns};
    for name in by_name {
        if table.column(name) is None {
            notes.append(f"ignored rule for unknown column '{name}'");
        }
    }
    rules: list[ColumnRule] = [];
    for prof in table.columns {
        rule = by_name.get(prof.name);
        if rule is None {
            notes.append(f"{prof.name}: model gave no rule, used profile defaults");
            rule = default_rule(prof);
        }
        enforce_profile_type(rule, prof, notes);
        rules.append(rule);
    }
    return rules;
}

"""Keep the measured dtype; the model may only widen INT to FLOAT.

Tiny models often mislabel types (dates as BOOL, ages as STR), and coercion can
make a wrong type pass silently, so the profile's measured type wins.
"""
def enforce_profile_type(rule: ColumnRule, prof: ColumnProfile, notes: list[str]) {
    guessed = prof.guessed_type;
    widened = guessed == ColType.INT and rule.dtype == ColType.FLOAT;
    if rule.dtype != guessed and not widened {
        notes.append(
            f"{rule.name}: model said {rule.dtype.name}, data is {guessed.name}; kept {guessed.name}"
        );
        rule.dtype = guessed;
    }
}

"""Drop rule parts that can never apply to the column's type."""
def sanitize(rule: ColumnRule, notes: list[str]) {
    numeric = rule.dtype in [ColType.INT, ColType.FLOAT];
    if not numeric and (rule.min_value is not None or rule.max_value is not None) {
        notes.append(f"{rule.name}: dropped min/max (not numeric)");
        rule.min_value = None;
        rule.max_value = None;
    }
    if rule.min_value is not None
    and rule.max_value is not None
    and rule.min_value > rule.max_value {
        notes.append(f"{rule.name}: dropped min/max (min > max)");
        rule.min_value = None;
        rule.max_value = None;
    }
    if rule.dtype != ColType.STR {
        if rule.allowed_values is not None or rule.regex is not None {
            notes.append(f"{rule.name}: dropped allowed_values/regex (not text)");
        }
        rule.allowed_values = None;
        rule.regex = None;
    }
    if rule.allowed_values is not None and len(rule.allowed_values) == 0 {
        rule.allowed_values = None;
    }
    if rule.regex is not None {
        try {
            _ = re.compile(rule.regex);
        } except re.error {
            notes.append(f"{rule.name}: dropped invalid regex {rule.regex!r}");
            rule.regex = None;
        }
    }
}

def dtype_str(rule: ColumnRule) -> str {
    match rule.dtype {
        case ColType.INT:
            return "Int64" if rule.nullable else "int64";
        case ColType.FLOAT:
            return "float64";
        case ColType.BOOL:
            return "boolean" if rule.nullable else "bool";
        case ColType.DATETIME:
            return "datetime64[ns]";
        case _:
            return "str";
    }
}

def num_literal(value: float, dtype: ColType) -> str {
    if dtype == ColType.INT and value == int(value) {
        return str(int(value));
    }
    return repr(value);
}

def column_code(rule: ColumnRule) -> str {
    checks: list[str] = [];
    if rule.min_value is not None {
        checks.append(f"pa.Check.ge({num_literal(rule.min_value, rule.dtype)})");
    }
    if rule.max_value is not None {
        checks.append(f"pa.Check.le({num_literal(rule.max_value, rule.dtype)})");
    }
    if rule.allowed_values is not None {
        checks.append(f"pa.Check.isin({[str(v) for v in rule.allowed_values]!r})");
    }
    if rule.regex is not None {
        checks.append(f"pa.Check.str_matches({rule.regex!r})");
    }
    args = [repr(dtype_str(rule))];
    if checks {
        args.append("checks=[" + ", ".join(checks) + "]");
    }
    args.append(f"nullable={rule.nullable}");
    if rule.unique {
        args.append("unique=True");
    }
    return f"        {rule.name!r}: pa.Column({', '.join(args)}),";
}

def to_code(rules: list[ColumnRule], source: str) -> str {
    lines = [
        f'"""Pandera schema proposed by csv-schema-proposer from {source}.',
        "",
        "Validate another file with:  python <this file> other.csv",
        '"""',
        "",
        "import sys",
        "",
        "import pandas as pd",
        "import pandera.pandas as pa",
        "",
        "schema = pa.DataFrameSchema(",
        "    {",
    ];
    lines.extend([column_code(r) for r in rules]);
    lines.extend(
        [
            "    },",
            "    coerce=True,",
            "    strict=True,",
            ")",
            "",
            "",
            'if __name__ == "__main__":',
            "    if len(sys.argv) != 2:",
            '        sys.exit(f"usage: python {sys.argv[0]} data.csv")',
            "    try:",
            "        schema.validate(pd.read_csv(sys.argv[1]), lazy=True)",
            "    except pa.errors.SchemaErrors as err:",
            '        print(err.failure_cases[["column", "check", "failure_case", "index"]].to_string())',
            "        sys.exit(1)",
            '    print(f"{sys.argv[1]}: OK")',
            "",
        ]
    );
    return "\n".join(lines);
}

"""Exec generated source and return its `schema` object."""
def load_schema(code: str) -> any {
    namespace: dict[str, any] = {"__name__": "proposed_schema"};
    exec(compile(code, "<proposed schema>", "exec"), namespace);
    return namespace["schema"];
}

"""Change `rule` so the given pandera check stops failing. False if no fix exists."""
def relax_check(
    rule: ColumnRule, check: str, prof: ColumnProfile, notes: list[str]
) -> bool {
    if check == "not_nullable" and not rule.nullable {
        rule.nullable = True;
        notes.append(f"{rule.name}: sample has nulls, made nullable");
        return True;
    }
    if check == "field_uniqueness" and rule.unique {
        rule.unique = False;
        notes.append(f"{rule.name}: sample has duplicates, dropped unique");
        return True;
    }
    if check.startswith("greater_than_or_equal_to") and rule.min_value is not None {
        notes.append(f"{rule.name}: sample breaks min {rule.min_value:g}, dropped it");
        rule.min_value = None;
        return True;
    }
    if check.startswith("less_than_or_equal_to") and rule.max_value is not None {
        notes.append(f"{rule.name}: sample breaks max {rule.max_value:g}, dropped it");
        rule.max_value = None;
        return True;
    }
    if check.startswith("isin") and rule.allowed_values is not None {
        notes.append(f"{rule.name}: sample has values outside allowed_values, dropped it");
        rule.allowed_values = None;
        return True;
    }
    if check.startswith("str_matches") and rule.regex is not None {
        notes.append(f"{rule.name}: sample doesn't match regex {rule.regex!r}, dropped it");
        rule.regex = None;
        return True;
    }
    if check.startswith("dtype") or check.startswith("coerce_dtype") {
        # Missing values break non-nullable coercion (e.g. NaN -> int64); that's
        # a nullability problem, not a wrong type.
        if not rule.nullable and prof.null_count > 0 {
            rule.nullable = True;
            notes.append(f"{rule.name}: sample has nulls, made nullable");
            return True;
        }
        # STR always coerces, so it is the last resort and never left.
        if rule.dtype == ColType.STR {
            return False;
        }
        fallback = prof.guessed_type if rule.dtype != prof.guessed_type else ColType.STR;
        notes.append(
            f"{rule.name}: sample isn't {rule.dtype.name}, switched to {fallback.name}"
        );
        rule.dtype = fallback;
        sanitize(rule, notes);
        return True;
    }
    return False;
}

"""Generate code, validate the sample against it, relax failures; return final code."""
def fit_to_sample(
    rules: list[ColumnRule], table: TableProfile, source: str, notes: list[str]
) -> str {
    for rule in rules {
        sanitize(rule, notes);
    }
    by_name: dict[str, ColumnRule] = {r.name: r for r in rules};
    for _ in range(MAX_RELAX_ROUNDS) {
        code = to_code(rules, source);
        schema = load_schema(code);
        try {
            _ = schema.validate(table.df.copy(), lazy=True);
            return code;
        } except pa.errors.SchemaErrors as err {
            failures = err.failure_cases[["column", "check"]].drop_duplicates();
            # One fix per column per round: a single cause (e.g. nulls) can
            # surface as several failures, so re-validate before fixing more.
            fixed_cols: set[str] = set();
            for (column, check) in failures.itertuples(index=False) {
                name = str(column);
                rule = by_name.get(name);
                prof = table.column(name);
                if name not in fixed_cols and rule is not None and prof is not None {
                    if relax_check(rule, str(check), prof, notes) {
                        fixed_cols.add(name);
                    }
                }
            }
            if not fixed_cols {
                raise RuntimeError(
                    f"could not fit schema to the sample:\n{failures.to_string()}"
                );
            }
        }
    }
    raise RuntimeError("schema still fails on the sample after relaxing");
}
