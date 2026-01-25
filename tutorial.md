# DiveInto Labs - Google Cloud Shell

![DiveInto](https://raw.githubusercontent.com/spurin/diveintolabs-cloudshell/main/logo.jpg)

This tutorial provides you with the DiveInto Labs, accessible in your browser 🚀

Firstly we'll warm up the DiveInto Labs Images. These are typically cached in the Google Container Mirrors.

Please be patient if this takes a while. For convenience you can send this to the terminal using the convenient 'Copy to Cloud Shell' icon on the top right of the text box

```bash
printf '%s\n' spurin/ssh-client spurin/diveinto-lab:portal spurin/diveinto-lab:node spurin/diveinto-lab:labapi | xargs -n1 -P4 docker pull -q
```

Launch the lab with the following -

```bash
docker compose -f oci://spurin/diveintolabs-cloudshell down >/dev/null 2>&1; docker compose -f oci://spurin/diveintolabs-cloudshell rm >/dev/null 2>&1; docker compose -f oci://spurin/diveintolabs-cloudshell up --no-build
```

When this completes, you'll see text similar to the following, ignore exit code 0 messages -

```terminal
Attaching to portal-diveinto-lab, shared-ssh-keys-diveinto-lab
```

To access the Portal, click the Web Preview Icon, if you cant find it, click -> <walkthrough-web-preview-icon>here</walkthrough-web-preview-icon> for a walkthrough on where to find it.  

Select 'Preview on Port 8080' and you're good to go!  

When accessing terminals, the default credentials are ansible/password
