#ifndef LK_RIME_BRIDGE_H
#define LK_RIME_BRIDGE_H
// All calls are confined to RimeInput's actor. The engine never logs input.
int lk_rime_initialize(const char *data_directory, const char *work_directory);
// Synchronous and confined to the same actor as query/selection. Reuses the
// initialized directories and prebuilt dictionaries; writes only to work_dir.
int lk_rime_deploy_schema(const char *schema_file);
int lk_rime_query(const char *schema, const char *input, int limit);
int lk_rime_query_singles(const char *schema, const char *input, int limit);
int lk_rime_query_page(const char *schema, const char *input, int start, int limit);
int lk_rime_query_ranked_page(const char *schema, const char *input, int start, int limit);
int lk_rime_next_index(void);
const char *lk_rime_text(int offset);
int lk_rime_index(int offset);
// -1 when unavailable; highlighting does not commit or learn a candidate.
int lk_rime_covers_input(int offset);
int lk_rime_candidate_covers_input(const char *schema, const char *input, int index, const char *expected);
int lk_rime_first_reading(const char *schema, const char *input, char *reading, int capacity);
int lk_rime_consumed(const char *schema, const char *input, int index, const char *expected);
void lk_rime_release_results(void);
#endif
