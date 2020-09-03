#!/usr/bin/env python
# Mini tool to work with https://secureshare.support share tool from CLI
import requests,re,sys
from bs4 import BeautifulSoup

class SecureShare():
    base_url = 'https://secureshare.support/'
    secret = None
    password = ""
    secure_link = None

    def create_secure_link(self):
        s = requests.Session()
        s.headers.update({'Referer': self.base_url})
        r = s.get(self.base_url)
        soup = BeautifulSoup(r.text, 'html.parser')
        csfrtoken = soup.find('input', {"name":"csrfmiddlewaretoken"})['value']
        data = { "csrfmiddlewaretoken" : csfrtoken,
                "secret" : self.secret,
                "password": self.password,
                "ttl_days" : 7,
                "ttl_hours": 0,
                "ttl_minutes" : 0
                }
        r = s.post(self.base_url, data = data)
        soup = BeautifulSoup(r.text, 'html.parser')
        self.secure_link = list((soup.findAll('a')))[0]['href']
        print(self.secure_link)

    def open_secure_link(self):
        s = requests.Session()
        s.headers.update({'Referer': self.base_url})
        r = s.get(self.secure_link)
        soup = BeautifulSoup(r.text, 'html.parser')
        csfrtoken = soup.find('input', {"name":"csrfmiddlewaretoken"})['value']
        data = { "csrfmiddlewaretoken" : csfrtoken,
                "cont" : "on"
                }
        r = s.post(self.secure_link, data = data)
        soup = BeautifulSoup(r.text, 'html.parser')
        cleanhtags = re.compile('<.*?>')
        print(re.sub(cleanhtags, '', str(soup.find('textarea'))))


    def __init__(self,secure_link = None, secret = None, password = None):
        if secure_link is not None:
            self.secure_link = secure_link
        if password is not None:
            self.password = password
        if secret is not None:
            self.secret = secret


if len(sys.argv) < 2:
    print('Error: an argument is required (secure link to open secret, text to create secret)')
    sys.exit(1)
arg = sys.argv[1]
pat = re.compile('https://secureshare.support/secret/.*')
if re.match(pat, arg) is not None:
    s = SecureShare(secure_link = arg)
    s.open_secure_link()
else:
    s = SecureShare(secret = arg)
    s.create_secure_link()
