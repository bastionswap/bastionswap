import { useQuery } from "@tanstack/react-query";
import { gql } from "graphql-request";
import { graphClient } from "@/config/subgraph";

const ISSUER_QUERY = gql`
  query IssuerProfile($id: ID!) {
    issuer(id: $id) {
      id
      reputationScore
      totalEscrowsCreated
      totalEscrowsCompleted
      totalTriggersActivated
      lastUpdated
      pools {
        id
        issuedToken
        escrow {
          isTriggered
        }
      }
    }
  }
`;

export interface IssuerProfile {
  id: string;
  reputationScore: string;
  totalEscrowsCreated: number;
  totalEscrowsCompleted: number;
  totalTriggersActivated: number;
  lastUpdated: string;
  pools: {
    id: string;
    issuedToken: string;
    escrow: { isTriggered: boolean } | null;
  }[];
}

export function useIssuerProfile(address: string | undefined) {
  return useQuery({
    queryKey: ["issuer", address],
    queryFn: () =>
      graphClient.request<{ issuer: IssuerProfile | null }>(ISSUER_QUERY, {
        id: address?.toLowerCase(),
      }),
    select: (data) => data.issuer,
    enabled: !!address,
  });
}
