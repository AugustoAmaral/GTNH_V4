rem don't forget to accept the EULA or it won't boot
java -Xms6G -Xmx6G -XX:+UseStringDeduplication -XX:+UseCompressedOops -XX:+UseCodeCacheFlushing -Dfml.readTimeout=180 -jar minecraftJarFile.jar nogui
