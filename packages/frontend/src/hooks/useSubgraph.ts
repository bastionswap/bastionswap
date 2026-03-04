import { useQuery } from "@tanstack/react-query";
import { graphClient } from "@/config/subgraph";
import type { RequestDocument } from "graphql-request";

export function useSubgraph<TData>(
  key: string[],
  document: RequestDocument,
  variables?: Record<string, unknown>,
  enabled = true
) {
  return useQuery({
    queryKey: key,
    queryFn: () =>
      graphClient.request<TData>(document, variables),
    enabled,
  });
}
