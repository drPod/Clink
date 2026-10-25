# Bump Demo Unipile simulation

Run the FastAPI server with `BUMP_UNIPILE_BASE_URL` set to the simulation's
`unipile` URL, a placeholder `UNIPILE_V2_API_KEY`, and a local `BUMP_PUBLIC_URL`.
The mock supports Hosted Auth link creation for Instagram and LinkedIn, account lookups, LinkedIn relations,
cursor pagination for the first account, and offset pagination for the second.
It returns 501 for any other operation. No live Instagram account is involved.
