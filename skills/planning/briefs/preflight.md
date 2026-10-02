Doc preflight for issue #__ISSUE__ in __REPO__. Do not edit anything. Do not delegate further.

Read #__ISSUE__ (`gh issue view __ISSUE__ --repo __REPO__ --comments`), spec #__SPEC__ (`gh issue view __SPEC__ --repo __REPO__ --comments`), and the project's workflow doc (__WORKFLOW_DOC__). Then read the code on origin/main that #__ISSUE__ touches: the files it names, their callers, and their tests.

List, max 250 words, one line each:
1. Contradictions between #__ISSUE__, #__SPEC__, the workflow doc and the code.
2. Defaults or formats #__ISSUE__ leaves unstated that the implementer must pick.
3. Failure cases with no stated behaviour.
4. Acceptance criteria that fight the spec or the code.

Tag each line `core` when it touches the ticket's core outcome, else `non-blocking`, and give your recommended ruling in a few words, preferring the smallest change. Then list every file the plan's author must read, one path per line. End with a STATUS line.
