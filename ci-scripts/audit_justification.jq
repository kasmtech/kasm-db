{
    vulnerabilities: [
        .Results[]?.Vulnerabilities[]?
        | select((.Severity == "CRITICAL" or .Severity == "HIGH") and has("FixedVersion"))
        | {
            package: .PkgName,
            range: .InstalledVersion,
            unique_finding: (.PkgID + "=>" + (.VulnerabilityID // "")),
            severity: (.Severity | ascii_downcase),
            title: .Title,
            cve: .VulnerabilityID,
            effects: .Description,
            fixAvailable: .FixedVersion
        }
    ]
}
