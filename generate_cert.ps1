$certPath = "cert.pfx"
$password = "123456"
$securePassword = ConvertTo-SecureString -String $password -Force -AsPlainText
$cert = New-SelfSignedCertificate -CertStoreLocation Cert:\CurrentUser\My -Subject "CN=Robert Ciobanu" -Type CodeSigningCert -FriendlyName "Manfredonia Manager"
Export-PfxCertificate -Cert $cert -FilePath $certPath -Password $securePassword
Write-Host "Certificate created at $certPath"
