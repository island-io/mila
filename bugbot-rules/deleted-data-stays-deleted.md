# Deleted user data must not come back

Deleting recordings, transcripts or voice profiles is a **privacy action**, not a
cache eviction. After it, no code path may write that data back.

The failure mode that shipped here: a user deleted their stored voice profiles
*while a recording was in progress*. The delete emptied the store and the file.
But the in-memory pool still held centroids copied at recording start, so the
end-of-recording write recreated the profile — the name returned, the file was
recreated, and the new embedding sat at 0.99983 cosine similarity to the deleted
one. By the numbers it was a "new" profile (fresh id, sample count 1). In effect
the erased voice was back and recognised just as well.

Partial resurrection is still resurrection. Judge it by what the user can
observe, not by whether the row is byte-identical.

## What to check

- **In-flight operations that began before the delete.** Do they still hold a
  copy? Does their completion path write it out?
- **Creation-on-absent semantics.** An `update`-style function that *creates*
  when the key is missing cannot be used as the guard — gating it would break
  legitimate creation. The guard belongs on the automatic path that should not
  run, not on the shared write primitive.
- **Adjacent lifecycle events.** A rename, or the absorbed side of a merge, can
  recreate an old name through the same path as a delete. Fixing delete alone
  often leaves those open.
- **Trashed or soft-deleted rows.** Anything that exposes data by id must apply
  the same exclusion as the listing path, so a retained id is not a way back in.

## What to flag

- A delete that clears persistence but leaves a loaded copy able to write back.
- A guard placed on a create-or-update primitive rather than on the caller.
- A delete path with no test covering "delete while an operation is running".
