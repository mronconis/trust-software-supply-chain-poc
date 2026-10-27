package com.redhat.demo;

import jakarta.ws.rs.GET;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.MediaType;
import java.time.Instant;
import java.util.Map;

@Path("/api")
public class SupplyChainResource {

    @GET
    @Path("/info")
    @Produces(MediaType.APPLICATION_JSON)
    public Map<String, String> info() {
        return Map.of(
            "application", "trusted-supply-chain-app",
            "version", "1.0.0-SNAPSHOT",
            "description", "PoC – Trusted Software Supply Chain",
            "builtAt", Instant.now().toString(),
            "signedWith", "cosign (Sigstore)",
            "sbomFormat", "CycloneDX 1.5",
            "analyzedBy", "GUAC (Trusted Profile Analyzer)"
        );
    }

    @GET
    @Produces(MediaType.TEXT_PLAIN)
    public String hello() {
        return "Trusted Supply Chain PoC – build ✔ | sign ✔ | verify ✔";
    }
}
