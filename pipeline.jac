"""The whole propose-a-schema pipeline as one callable, shared by the CLI and web app.

profile -> model proposal -> reconcile + fit to sample -> pandera code.
"""

import copy;
import time;
import pandas as pd;
import from jaclang.byllm.lib { register_llm_call_hook, unregister_llm_call_hook }
import from propose { ColumnRule, CsvSample, current_model_name }
import from profiling { profile_df }
import from render { reconcile, fit_to_sample }

obj ProposalResult {
    has source: str;
    has model_name: str;
    has elapsed_s: float = 0.0;
    has profile: str = "";
    has sample_rows: str = "";
    has model_reply: str = "";
    has model_rules: list[ColumnRule] = [];
    has final_rules: list[ColumnRule] = [];
    has notes: list[str] = [];
    has schema_code: str = "";
    has error: str = "";
}

"""Run every stage on `df`. Model and fitting failures land in `error`, not exceptions."""
def run_pipeline(df: pd.DataFrame, source: str) -> ProposalResult {
    result = ProposalResult(source=source, model_name=current_model_name());
    table = profile_df(df);
    result.profile = table.to_prompt();
    result.sample_rows = table.sample_rows();

    replies: list[str] = [];
    def capture(rec: dict[str, any]) {
        reply = rec.get("reply") or {};
        replies.append(str(reply.get("content") or ""));
    }

    started = time.monotonic();
    register_llm_call_hook(capture);
    try {
        proposal = CsvSample(
            column_profile=result.profile, sample_rows=result.sample_rows
        ).propose_schema();
    } except Exception as err {
        # Connection problems surface as litellm exceptions, so catch broadly.
        result.error = f"Model call failed: {err}";
        return result;
    } finally {
        unregister_llm_call_hook(capture);
        result.elapsed_s = round(time.monotonic() - started, 1);
        result.model_reply = replies[-1] if replies else "";
    }

    # reconcile/fit_to_sample mutate rules; keep the model's answer as given.
    result.model_rules = copy.deepcopy(proposal.columns);
    try {
        result.final_rules = reconcile(proposal, table, result.notes);
        result.schema_code = fit_to_sample(
            result.final_rules, table, source, result.notes
        );
    } except RuntimeError as err {
        result.error = f"Could not fit a schema to the sample: {err}";
    }
    return result;
}
