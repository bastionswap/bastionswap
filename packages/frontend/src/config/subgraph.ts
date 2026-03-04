import { GraphQLClient } from "graphql-request";

const SUBGRAPH_URL =
  process.env.NEXT_PUBLIC_SUBGRAPH_URL ||
  "https://api.studio.thegraph.com/query/0/bastionswap-base-sepolia/version/latest";

export const graphClient = new GraphQLClient(SUBGRAPH_URL);
