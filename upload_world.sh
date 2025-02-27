sshpass -p "0m3ayp02jpn0" sftp -P 2022 -o StrictHostKeyChecking=no pjh6jgy3.fee655f1@br-pro-10.reis.host << EOF
put -r ./World/* /World/
bye
EOF