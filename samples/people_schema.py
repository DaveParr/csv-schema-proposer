"""Pandera schema proposed by csv-schema-proposer from people.csv.

Validate another file with:  python <this file> other.csv
"""

import sys

import pandas as pd
import pandera.pandas as pa

schema = pa.DataFrameSchema(
    {
        'id': pa.Column('int64', checks=[pa.Check.ge(1), pa.Check.le(10)], nullable=False, unique=True),
        'name': pa.Column('str', nullable=False, unique=True),
        'email': pa.Column('str', nullable=False, unique=True),
        'age': pa.Column('Int64', checks=[pa.Check.ge(36), pa.Check.le(101)], nullable=True, unique=True),
        'height_m': pa.Column('float64', checks=[pa.Check.ge(1.6), pa.Check.le(1.85)], nullable=True, unique=True),
        'signup_date': pa.Column('datetime64[ns]', nullable=False, unique=True),
        'plan': pa.Column('str', nullable=False),
        'is_active': pa.Column('bool', nullable=False),
    },
    coerce=True,
    strict=True,
)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(f"usage: python {sys.argv[0]} data.csv")
    try:
        schema.validate(pd.read_csv(sys.argv[1]), lazy=True)
    except pa.errors.SchemaErrors as err:
        print(err.failure_cases[["column", "check", "failure_case", "index"]].to_string())
        sys.exit(1)
    print(f"{sys.argv[1]}: OK")
