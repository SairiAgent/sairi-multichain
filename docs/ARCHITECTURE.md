# Initial architecture

Candidate: canonical Base lockbox / OFTAdapter and destination backed representation, with mature authenticated message verification. No protocol or deployment has been selected as verified yet. Existing adapters must be investigated before creating another mint domain. CCIP is an alternative subject to actual network support.

The local vertical slice will isolate bridge state, input-asset fee collection, configuration validation, accounting evidence and a explicitly synthetic pool simulation. Local mocks do not prove external verifier security or target-chain support.
