# Etapa base
FROM nginx:alpine

# Copia um HTML simples (pode criar um index.html)
COPY index.html /usr/share/nginx/html/index.html

# Expõe a porta padrão do nginx
EXPOSE 80

# Comando padrão
CMD ["nginx", "-g", "daemon off;"]