# Interaction grouping and path lookup

InterpretationEngine groups equivalent interactions before conformance evaluation.
The original list-based fold scanned all previous groups for each interaction and
rebuilt identity tuples and evidence strings during every comparison. Large
observations could spend minutes in this fold, with quadratic work and allocation.

Group by the existing interaction identity in a hash table, computing each input's
key once. Accumulate call sites without sorting after every insertion. Sort the
completed groups by their keys and sort/deduplicate sites once per group. This
preserves deterministic ordering, distinct evidence paths and every source site
used by path rules. Identity and conformance semantics remain unchanged.

The unit regression covers identity distinctions, site preservation, insertion
order and 40,000 interactions in 20,000 groups. Its allocation budget detects
quadratic key construction without depending on machine speed. Existing
source-to-report acceptance scenarios verify the full interpretation pipeline.

## Path lookup

After grouping, path evaluation also scanned every interaction for every execution
path and compared each interaction's sites with every step. Index interactions
once by the exact source path, line and column instead. Resolve each path through
that index, deduplicate by the input interaction's ordinal and restore input order.
This preserves multiple interactions at one site and every evidence path, including
structurally equal entries, while avoiding a full-observation scan per path.

The path regression checks multisite matches, repeated steps, distinct entries,
file/column mismatches and 20,000 indexed lookups under an allocation budget.
