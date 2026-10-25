"""Deterministic pandas profiling of a CSV, rendered as compact text for the model."""

import pandas as pd;
import from propose { ColType }

obj ColumnProfile {
    has name: str;
    has pandas_dtype: str;
    has guessed_type: ColType;
    has row_count: int;
    has null_count: int;
    has unique_count: int;
    has min_value: float | None = None;
    has max_value: float | None = None;
    has examples: list[str] = [];

    def to_line -> str {
        parts = [
            f"guessed_type={self.guessed_type.name}",
            f"nulls={self.null_count}/{self.row_count}",
            f"unique={self.unique_count}",
        ];
        if self.min_value is not None {
            parts.append(f"min={self.min_value:g}");
        }
        if self.max_value is not None {
            parts.append(f"max={self.max_value:g}");
        }
        parts.append(f"examples={self.examples}");
        return f"- {self.name}: " + ", ".join(parts);
    }
}

obj TableProfile {
    has df: pd.DataFrame;
    has columns: list[ColumnProfile];

    def to_prompt -> str {
        return "\n".join([c.to_line() for c in self.columns]);
    }

    def sample_rows(n: int = 5) -> str {
        return str(self.df.head(n).to_csv(index=False));
    }

    def column(name: str) -> ColumnProfile | None {
        for c in self.columns {
            if c.name == name {
                return c;
            }
        }
        return None;
    }
}

def guess_type(series: pd.Series) -> ColType {
    values = series.dropna();
    if pd.api.types.is_bool_dtype(series) {
        return ColType.BOOL;
    }
    if pd.api.types.is_integer_dtype(series) {
        return ColType.INT;
    }
    if pd.api.types.is_float_dtype(series) {
        # Integer columns with gaps are read as float; keep them INT.
        if len(values) > 0 and bool(values.mod(1).eq(0).all()) {
            return ColType.INT;
        }
        return ColType.FLOAT;
    }
    if len(values) > 0 {
        try {
            _ = pd.to_datetime(values, format="ISO8601");
            return ColType.DATETIME;
        } except (ValueError, TypeError) {}
    }
    return ColType.STR;
}

def profile_column(name: str, series: pd.Series) -> ColumnProfile {
    values = series.dropna();
    guessed = guess_type(series);
    prof = ColumnProfile(
        name=name,
        pandas_dtype=str(series.dtype),
        guessed_type=guessed,
        row_count=len(series),
        null_count=int(series.isna().sum()),
        unique_count=int(values.nunique()),
        examples=[str(v) for v in values.unique()[:5]],
    );
    if guessed in [ColType.INT, ColType.FLOAT] and len(values) > 0 {
        prof.min_value = float(values.min());
        prof.max_value = float(values.max());
    }
    return prof;
}

def load_csv(path: str, rows: int) -> pd.DataFrame {
    return pd.read_csv(path, nrows=rows);
}

def profile_df(df: pd.DataFrame) -> TableProfile {
    return TableProfile(
        df=df,
        columns=[profile_column(str(name), df[name]) for name in df.columns],
    );
}
